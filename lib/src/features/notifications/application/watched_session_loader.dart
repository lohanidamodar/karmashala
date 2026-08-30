import 'dart:io';

import '../../../core/util/clock.dart';
import '../../agents/data/agent_hook_receiver.dart';
import '../../agents/data/agent_installation_dao.dart';
import '../../cli_detection/data/imported_session_dao.dart';
import '../../sessions/data/session_dao.dart';
import '../../sessions/domain/session_status.dart';
import '../domain/agent_session_key.dart';
import '../domain/watched_session.dart';

/// Picks the sessions worth asking the status pipeline about.
///
/// Reading a status is not free — a state-file lookup tails the transcript from
/// disk — so this is a filter, not an enumeration. A session qualifies when
/// either an agent hook has already reported on it (in-memory, always cheap) or
/// its transcript changed recently enough to still be live.
class WatchedSessionLoader {
  WatchedSessionLoader({
    required this.sessionDao,
    required this.importedSessionDao,
    required this.installationDao,
    required this.hookReports,
    required this.clock,
    this.activeWindow = const Duration(minutes: 30),
    this.coldRecheck = const Duration(minutes: 1),
    this.limit = 60,
  });

  final SessionDao sessionDao;
  final ImportedSessionDao importedSessionDao;
  final AgentInstallationDao installationDao;
  final AgentHookReports hookReports;
  final Clock clock;

  /// How recently a transcript must have changed for its session to count as
  /// live. Anything colder is history, and history does not raise toasts.
  final Duration activeWindow;

  /// How long a transcript already found cold is left alone before it is
  /// checked again. Without this a workspace with hundreds of imported sessions
  /// pays a full filesystem sweep every poll for files that have not changed in
  /// weeks. The cost is up to this much latency before a revived session starts
  /// being watched — and only when hooks are not installed, since a hook report
  /// skips the check entirely.
  final Duration coldRecheck;

  /// Upper bound on sessions watched per poll, newest first. A workspace with
  /// thousands of imported sessions must not turn a 5-second tick into a
  /// filesystem sweep.
  final int limit;

  /// Cold transcripts, and the instant each becomes worth checking again.
  final Map<String, DateTime> _coldUntil = {};

  List<WatchedSession> load() {
    final now = clock.nowUtc();
    final agentIdByInstallation = {
      for (final installation in installationDao.getAll())
        installation.id: installation.agentId,
    };

    // (session, recency) pairs, so the cap keeps the most recently active.
    final candidates = <(WatchedSession, DateTime)>[];

    for (final session in sessionDao.getAll()) {
      final externalId = session.externalSessionId;
      final agentId = agentIdByInstallation[session.agentInstallationId];
      if (externalId == null || agentId == null) continue;
      if (_isOver(session.status)) continue;
      // Native sessions carry no transcript path, so their status can only come
      // from hooks — an in-memory lookup, cheap enough to always include.
      candidates.add((
        WatchedSession(
          key: AgentSessionKey(agentId, externalId),
          label: session.title,
          openId: session.id,
          imported: false,
        ),
        now,
      ));
    }

    for (final session in importedSessionDao.getAll()) {
      final key = AgentSessionKey(session.cli, session.externalId);
      // A hook report is proof the session is live, and costs a map lookup, so
      // it is checked before anything touches the disk.
      final hooked = hookReports.latest(key.agentId, key.sessionId) != null;
      if (!hooked && _stillCold(session.filePath, now)) continue;

      final modified = _lastModified(session.filePath);
      final warm = modified != null && now.difference(modified) <= activeWindow;
      if (!hooked && !warm) {
        _coldUntil[session.filePath] = now.add(coldRecheck);
        continue;
      }
      _coldUntil.remove(session.filePath);
      candidates.add((
        WatchedSession(
          key: key,
          label: session.displayTitle,
          openId: session.id,
          imported: true,
          stateFilePath: session.filePath,
        ),
        modified ?? now,
      ));
    }

    candidates.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final candidate in candidates.take(limit)) candidate.$1];
  }

  bool _stillCold(String path, DateTime now) {
    final until = _coldUntil[path];
    return until != null && now.isBefore(until);
  }

  /// A workspace session in a terminal state can no longer produce status.
  bool _isOver(SessionStatus status) =>
      status == SessionStatus.completed ||
      status == SessionStatus.cancelled ||
      status == SessionStatus.failed;

  DateTime? _lastModified(String path) {
    try {
      final file = File(path);
      return file.existsSync() ? file.lastModifiedSync().toUtc() : null;
    } catch (_) {
      return null;
    }
  }
}
