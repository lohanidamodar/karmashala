import 'dart:io';

import '../../../core/util/clock.dart';
import '../../agents/data/agent_hook_receiver.dart';
import '../../agents/data/agent_installation_dao.dart';
import '../../cli_detection/data/imported_session_dao.dart';
import '../../sessions/data/session_dao.dart';
import '../../sessions/domain/session_status.dart';
import '../domain/agent_session_key.dart';
import '../domain/watched_session.dart';

/// Every session worth holding a status for.
///
/// An enumeration with one liveness filter, not a ranking. Until Loop 87 this
/// also truncated its own answer at 60 entries, newest first — which meant a
/// workspace with more than sixty live sessions silently stopped watching the
/// rest, and a session that dropped out of the capped set and came back looked
/// like a first observation, so its transition was suppressed. The cap is gone:
/// what a status *costs* is now rationed by `SessionStatusRegistry`'s probe
/// budget, which spends it on the disk reads rather than on membership.
///
/// The one filter that remains is liveness, and it is about the filesystem, not
/// about count: an imported transcript nothing has touched for half an hour is
/// history, and history does not raise toasts.
class WatchedSessionLoader {
  WatchedSessionLoader({
    required this.sessionDao,
    required this.importedSessionDao,
    required this.installationDao,
    required this.hookReports,
    required this.clock,
    this.activeWindow = const Duration(minutes: 30),
    this.coldRecheck = const Duration(minutes: 1),
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
      final agentId = agentIdByInstallation[session.agentInstallationId];
      if (agentId == null) continue;
      if (_isOver(session.status)) continue;
      // The CLI's own id when it has announced one — the key hooks and state
      // files share — and our row id when it has not. A session the agent has
      // not named yet still has a screen, and the screen is a status source:
      // keying it by the row id is exactly what the per-card badge always did,
      // and it is why the ambient pipeline used to report `unknown` for a
      // session the visible badge could read perfectly well.
      final externalId = session.externalSessionId;
      candidates.add((
        WatchedSession(
          key: AgentSessionKey(
            agentId,
            externalId == null || externalId.isEmpty ? session.id : externalId,
          ),
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

    // Newest first. Ordering, not selection: nothing is dropped for sorting
    // late any more. It decides which waiting session the tray names first.
    candidates.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final candidate in candidates) candidate.$1];
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
