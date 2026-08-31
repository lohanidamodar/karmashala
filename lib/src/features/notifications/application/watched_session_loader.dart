import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

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
///
/// ## [load] does not touch the disk
///
/// It reads a *sample* — the last-modified time the sampler last saw — and
/// starts a pass to refresh whatever is due. The pass stats asynchronously, so
/// it runs on `dart:io`'s thread pool and the caller's isolate only sees the
/// completions.
///
/// This is the shape of Loop 90's periodic hitch, and it is worth spelling out
/// because the old code looked innocent. `SessionStatusRegistry` calls [load]
/// on the UI isolate every 1.2 seconds, and [load] used to `existsSync()` and
/// `lastModifiedSync()` every transcript due a recheck. On the owner's machine
/// that is 107 transcripts, 64 of them under `\\wsl.localhost\...`, at 1.19 ms
/// for the pair — 67 ms of blocked UI thread. And because every cold transcript
/// was found cold in the same cycle and given the same deadline, the whole
/// workspace came due in the *same* cycle: fifty-nine free ticks, then one
/// 67 ms stall, once a minute, for as long as the app ran.
///
/// The cost of reading a sample instead of the file is that a transcript the
/// sampler has not reached yet is not watched yet — one cycle at startup, and
/// nothing after that. It is the same trade `coldRecheck` already made, for a
/// minute rather than a second.
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

  /// How many transcripts the sampler stats at once.
  static const int _sampleConcurrency = 4;

  /// What the sampler last saw for each transcript.
  ///
  /// [load] reads this and nothing else: it is what makes reading the workspace
  /// cost no filesystem call at all, whatever the workspace's size.
  final Map<String, _Sample> _samples = {};

  /// The sampling pass in flight, so a cycle cannot start a second one over the
  /// same files and [settle] has something to wait for.
  Future<void>? _sampling;

  /// The sampling pass in flight, or nothing to wait for.
  ///
  /// For tests and benchmarks, which need "the disk has been read" to be a
  /// moment they can name. Production never awaits it: the next cycle is 1.2
  /// seconds away and reads whatever the sampler has finished by then.
  Future<void> settle() => _sampling ?? Future<void>.value();

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

    final known = <String>{};
    final due = <String>[];
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
      // A file nobody has sampled yet is not yet an answer. It becomes one on
      // the next cycle, 1.2 seconds later — a wait this class already accepted
      // up to a minute of in `coldRecheck`, and one a hook short-circuits.
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

    // Newest first. Ordering, not selection: nothing is dropped for sorting
    // late any more. It decides which waiting session the tray names first.
    candidates.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final candidate in candidates) candidate.$1];
  }

  /// A workspace session in a terminal state can no longer produce status.
  bool _isOver(SessionStatus status) =>
      status == SessionStatus.completed ||
      status == SessionStatus.cancelled ||
      status == SessionStatus.failed;

  /// Reads the last-modified time of every transcript in [paths] — **off the
  /// calling isolate**.
  ///
  /// `File.stat()` rather than `existsSync()` + `lastModifiedSync()`, and this
  /// is the whole point of the class's rewrite in Loop 90. `dart:io`'s
  /// asynchronous file calls are dispatched to its own thread pool and only
  /// their completions come back here; the synchronous pair blocks the isolate
  /// for the round trip. On the owner's machine 64 of 107 transcripts live
  /// under `\\wsl.localhost\...`, where the synchronous pair measured **1.19
  /// ms** against **0.07 ms** on local NTFS — so one sweep of the workspace was
  /// 67 ms during which nothing painted.
  ///
  /// Bounded rather than a `Future.wait` over everything: a hundred transcripts
  /// on a network share should not become a hundred open handles.
  void _sample(List<String> paths, DateTime now) {
    if (_sampling != null) return;
    final pass = _sampleAll(paths, now);
    _sampling = pass;
    unawaited(pass.whenComplete(() => _sampling = null));
  }

  Future<void> _sampleAll(List<String> paths, DateTime now) async {
    final queue = Queue<String>.of(paths);
    final workers = math.min(_sampleConcurrency, paths.length);
    await Future.wait([
      for (var i = 0; i < workers; i++) _drain(queue, now),
    ]);
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

  /// When a cold [path] is worth stat-ing again: one window, plus an offset
  /// derived from the path itself.
  ///
  /// The offset is the other half of the periodic hitch. Every cold transcript
  /// used to be found cold in the *same* cycle and given the *same* deadline,
  /// so they all came due together a minute later — fifty-nine free ticks and
  /// then one that swept the entire workspace, for as long as the app ran.
  /// Deriving the offset from the path rather than from a random number keeps
  /// it stable across passes, so a file does not drift earlier every cycle.
  Duration _recheckFor(String path) =>
      coldRecheck +
      Duration(
        microseconds:
            coldRecheck.inMicroseconds * (path.hashCode.abs() % 1024) ~/ 1024,
      );
}

/// The last-modified time a transcript had when it was sampled, and when it is
/// worth looking again. `null` for a file that was missing or unreadable, which
/// is the same answer as "nothing has happened here".
class _Sample {
  const _Sample(this.modified, this.dueAt);

  final DateTime? modified;
  final DateTime dueAt;
}
