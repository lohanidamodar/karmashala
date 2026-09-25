import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:karmashala_core/util.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
import '../../agents/data/agent_installation_dao.dart';
import '../../cli_detection/data/imported_session_dao.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_notifications/watched.dart';

/// Every session worth holding a status for. [load] never touches the disk: it
/// reads the sampler's last answer, so any workspace size costs no stat.
class WatchedSessionLoader {
  WatchedSessionLoader({
    required this.sessionDao,
    required this.importedSessionDao,
    required this.installationDao,
    required this.hookReports,
    required this.clock,
    this.isPaneLive,
    this.transcriptPathFor,
    this.activeWindow = const Duration(minutes: 30),
    this.coldRecheck = const Duration(minutes: 1),
  });

  final SessionDao sessionDao;
  final ImportedSessionDao importedSessionDao;
  final AgentInstallationDao installationDao;
  final AgentHookReports hookReports;
  final Clock clock;

  /// Whether a pane of this app instance is running a process. Null counts no
  /// pane as live — a row's `pane_id` outlives the pane it names.
  final bool Function(String paneId)? isPaneLive;

  /// The transcript the status registry resolved for a native row, while it
  /// watches it. Remembered here so a row that lost its pane is still watched
  /// while that file keeps changing.
  final String? Function(String sessionId)? transcriptPathFor;

  /// How recently a transcript must have changed for its session to count as
  /// live. Anything colder is history, and history does not raise toasts.
  final Duration activeWindow;

  /// How long a transcript already found cold is left alone. The cost is up to
  /// this much latency before a revived session is watched; a hook skips it.
  final Duration coldRecheck;

  /// How many transcripts the sampler stats at once.
  static const int _sampleConcurrency = 4;

  /// What the sampler last saw for each transcript — [load] reads this and
  /// nothing else.
  final Map<String, _Sample> _samples = {};

  /// Native row id → the transcript [transcriptPathFor] once answered.
  final Map<String, String> _nativeTranscripts = {};

  /// The sampling pass in flight, so a cycle cannot start a second one over the
  /// same files and [settle] has something to wait for.
  Future<void>? _sampling;

  /// The sampling pass in flight, or nothing to wait for. For tests: production
  /// never awaits it, the next cycle reads whatever the sampler has finished.
  Future<void> settle() => _sampling ?? Future<void>.value();

  List<WatchedSession> load() {
    final now = clock.nowUtc();
    final agentIdByInstallation = {
      for (final installation in installationDao.getAll())
        installation.id: installation.agentId,
    };

    // (session, recency) pairs, so the cap keeps the most recently active.
    final candidates = <(WatchedSession, DateTime)>[];
    final known = <String>{};
    final due = <String>[];
    final nativeIds = <String>{};

    for (final session in sessionDao.getAll()) {
      final agentId = agentIdByInstallation[session.agentInstallationId];
      if (agentId == null) continue;
      if (_isOver(session.status)) continue;
      // The CLI's own id when it has announced one — the key hooks and state
      // files share — and our row id when it has not, which still has a screen.
      final externalId = session.externalSessionId;
      final key = AgentSessionKey(
        agentId,
        externalId == null || externalId.isEmpty ? session.id : externalId,
      );
      nativeIds.add(session.id);
      if (!_nativeIsLive(session, key, now, known, due)) continue;
      candidates.add((
        WatchedSession(
          key: key,
          label: session.title,
          openId: session.id,
          imported: false,
          paneId: session.paneId,
        ),
        now,
      ));
    }

    _nativeTranscripts.removeWhere((id, _) => !nativeIds.contains(id));

    for (final session in importedSessionDao.getAll()) {
      final key = AgentSessionKey(session.cli, session.externalId);
      // A hook report is proof the session is live, and costs a map lookup, so
      // it is checked before anything else.
      final hooked = hookReports.latest(key.agentId, key.sessionId) != null;
      known.add(session.filePath);

      final sample = _samples[session.filePath];
      if (sample == null || !now.isBefore(sample.dueAt)) {
        due.add(session.filePath);
      }
      // A file nobody has sampled yet is not yet an answer; it becomes one on
      // the next cycle, and a hook short-circuits the wait.
      if (sample == null && !hooked) continue;

      final modified = sample?.modified;
      final warm = modified != null && now.difference(modified) <= activeWindow;
      if (!hooked && !warm) continue;
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
    // A session removed from the workspace takes its sample with it.
    _samples.removeWhere((path, _) => !known.contains(path));
    if (due.isNotEmpty) _sample(due, now);

    // Newest first. Ordering, not selection — it decides which waiting session
    // the tray names first.
    candidates.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final candidate in candidates) candidate.$1];
  }

  /// Whether a native row has any evidence of running. Its status cannot say:
  /// `unknown` is what a row whose pane died is left as, and it lasts forever.
  bool _nativeIsLive(
    Session session,
    AgentSessionKey key,
    DateTime now,
    Set<String> known,
    List<String> due,
  ) {
    // Learned while the row is watched and sampled from then on, so the cycle
    // its pane dies already knows whether the transcript is still moving.
    final resolved = transcriptPathFor?.call(session.id);
    if (resolved != null) _nativeTranscripts[session.id] = resolved;
    final path = _nativeTranscripts[session.id];
    DateTime? modified;
    if (path != null) {
      known.add(path);
      final sample = _samples[path];
      if (sample == null || !now.isBefore(sample.dueAt)) due.add(path);
      modified = sample?.modified;
    }

    final paneId = session.paneId;
    if (paneId != null && (isPaneLive?.call(paneId) ?? false)) return true;
    if (hookReports.latest(key.agentId, key.sessionId) != null) return true;
    // Launched into a terminal we cannot see: its hooks or its transcript are
    // all it will ever show, and neither exists for its first moments.
    if (session.surface == SessionSurface.external &&
        now.difference(session.createdAt) <= activeWindow) {
      return true;
    }
    return modified != null && now.difference(modified) <= activeWindow;
  }

  /// A workspace session in a terminal state can no longer produce status.
  bool _isOver(SessionStatus status) =>
      status == SessionStatus.completed ||
      status == SessionStatus.cancelled ||
      status == SessionStatus.failed;

  /// Reads every transcript's last-modified time *off the calling isolate*:
  /// async `stat()`, bounded, because the sync pair blocks for the round trip.
  void _sample(List<String> paths, DateTime now) {
    if (_sampling != null) return;
    final pass = _sampleAll(paths, now);
    _sampling = pass;
    unawaited(pass.whenComplete(() => _sampling = null));
  }

  Future<void> _sampleAll(List<String> paths, DateTime now) async {
    final queue = Queue<String>.of(paths);
    final workers = math.min(_sampleConcurrency, paths.length);
    await Future.wait([for (var i = 0; i < workers; i++) _drain(queue, now)]);
  }

  Future<void> _drain(Queue<String> queue, DateTime now) async {
    while (queue.isNotEmpty) {
      final path = queue.removeFirst();
      DateTime? modified;
      try {
        final stat = await File(path).stat();
        modified = stat.type == FileSystemEntityType.notFound
            ? null
            : stat.modified.toUtc();
      } catch (_) {
        // A file we cannot read is the same answer as one that is not there.
        modified = null;
      }
      final warm = modified != null && now.difference(modified) <= activeWindow;
      _samples[path] = _Sample(
        modified,
        // A live transcript is re-read every cycle, which now costs the isolate
        // nothing; a cold one waits out its window.
        warm ? now : now.add(_recheckFor(path)),
      );
    }
  }

  /// When a cold [path] is worth stat-ing again: one window plus a path-derived
  /// offset, so cold transcripts do not all come due in the same cycle.
  Duration _recheckFor(String path) =>
      coldRecheck +
      Duration(
        microseconds:
            coldRecheck.inMicroseconds * (path.hashCode.abs() % 1024) ~/ 1024,
      );
}

/// The last-modified time a transcript had when sampled, and when to look
/// again. `null` means missing or unreadable — the same as "nothing happened".
class _Sample {
  const _Sample(this.modified, this.dueAt);

  final DateTime? modified;
  final DateTime dueAt;
}
