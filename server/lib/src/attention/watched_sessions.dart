import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:agent_cli/discovery.dart' show AgentInstallation;
import 'package:agent_cli/read.dart' show ImportedSession;
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';

/// What the server's store holds that the watch set is chosen from, read
/// afresh only when a write moved it ([WatchedSessions.invalidate]).
abstract interface class WatchedRows {
  List<Session> sessions();

  /// Imported history, superseded records already left out.
  List<ImportedSession> imported();

  List<AgentInstallation> installations();
}

/// **Every session worth holding a status for**, at the server (slice 5c) —
/// the app's `WatchedSessionLoader`, moved. [load] never touches the disk: it
/// reads the rows the store last answered and the sampler's last stat of
/// each transcript, so any workspace size costs no stat per cycle.
///
/// A native row is watched while it shows any evidence of running: the
/// server runs it ([isRunningOnHost]), a hook named it, it was launched into a
/// terminal the server cannot see and is young, or its transcript is still
/// moving. A recorded ending (`completed`, `cancelled`, `failed`) drops it
/// unless the server still runs it. Imported history is watched while a hook
/// names it or its transcript moved within [activeWindow].
class WatchedSessions {
  WatchedSessions({
    required this.rows,
    required this.hookReports,
    required this.clock,
    this.isRunningOnHost,
    this.transcriptPathFor,
    this.activeWindow = const Duration(minutes: 30),
    this.coldRecheck = const Duration(minutes: 1),
    this.rowsRecheck = const Duration(seconds: 30),
  });

  final WatchedRows rows;
  final AgentHookReports hookReports;
  final Clock clock;

  /// Whether the server runs row [String]'s agent now.
  final bool Function(String sessionId)? isRunningOnHost;

  /// The transcript the status registry located for a native row while it
  /// watched it — remembered so a row whose process ended is still watched
  /// while that file keeps moving.
  final String? Function(String sessionId)? transcriptPathFor;

  /// How recently a transcript must have moved for its session to count as
  /// live. Anything colder is history, and history raises no news.
  final Duration activeWindow;

  /// How long a transcript already found cold is left alone.
  final Duration coldRecheck;

  /// The longest the rows are trusted without a write having said so — a
  /// safety net, not the path: every write the data service tells
  /// invalidates them.
  final Duration rowsRecheck;

  static const int _sampleConcurrency = 4;

  final Map<String, _Sample> _samples = {};
  final Map<String, String> _nativeTranscripts = {};
  Future<void>? _sampling;

  List<Session>? _sessions;
  List<ImportedSession>? _imported;
  Map<String, String>? _agentOf;
  DateTime? _rowsReadAt;

  /// The sampling pass in flight, or nothing: for tests.
  Future<void> settle() => _sampling ?? Future<void>.value();

  /// A write moved the rows: read them again on the next [load].
  void invalidate() {
    _sessions = null;
    _imported = null;
    _agentOf = null;
  }

  void _readRows(DateTime now) {
    final stale =
        _sessions == null ||
        _rowsReadAt == null ||
        now.difference(_rowsReadAt!) > rowsRecheck;
    if (!stale) return;
    _sessions = rows.sessions();
    _imported = rows.imported();
    _agentOf = {
      for (final installation in rows.installations())
        installation.id: installation.agentId,
    };
    _rowsReadAt = now;
  }

  List<WatchedSession> load() {
    final now = clock.nowUtc();
    _readRows(now);
    final agentOf = _agentOf!;

    // (session, recency) pairs, so the order puts the most recent first.
    final candidates = <(WatchedSession, DateTime)>[];
    final known = <String>{};
    final due = <String>[];
    final nativeIds = <String>{};

    for (final session in _sessions!) {
      final agentId = agentOf[session.agentInstallationId];
      if (agentId == null) continue;
      if (_isOver(session.status) && !_runningOnHost(session.id)) continue;
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

    for (final session in _imported!) {
      final key = AgentSessionKey(session.cli, session.externalId);
      final hooked = hookReports.latest(key.agentId, key.sessionId) != null;
      known.add(session.filePath);
      final sample = _samples[session.filePath];
      if (sample == null || !now.isBefore(sample.dueAt)) {
        due.add(session.filePath);
      }
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
    _samples.removeWhere((path, _) => !known.contains(path));
    if (due.isNotEmpty) _sample(due, now);

    candidates.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final candidate in candidates) candidate.$1];
  }

  bool _runningOnHost(String sessionId) =>
      isRunningOnHost?.call(sessionId) ?? false;

  bool _nativeIsLive(
    Session session,
    AgentSessionKey key,
    DateTime now,
    Set<String> known,
    List<String> due,
  ) {
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
    if (_runningOnHost(session.id)) return true;
    if (hookReports.latest(key.agentId, key.sessionId) != null) return true;
    // Launched into a terminal the server cannot see: its hooks or its
    // transcript are all it will ever show, and neither exists at first.
    if (session.surface == SessionSurface.external &&
        now.difference(session.createdAt) <= activeWindow) {
      return true;
    }
    return modified != null && now.difference(modified) <= activeWindow;
  }

  bool _isOver(SessionStatus status) =>
      status == SessionStatus.completed ||
      status == SessionStatus.cancelled ||
      status == SessionStatus.failed;

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
      } on Object {
        modified = null;
      }
      final warm = modified != null && now.difference(modified) <= activeWindow;
      _samples[path] = _Sample(
        modified,
        warm ? now : now.add(_recheckFor(path)),
      );
    }
  }

  /// When a cold [path] is worth a stat again: one window plus a path-derived
  /// offset, so cold transcripts do not all come due in one cycle.
  Duration _recheckFor(String path) =>
      coldRecheck +
      Duration(
        microseconds:
            coldRecheck.inMicroseconds * (path.hashCode.abs() % 1024) ~/ 1024,
      );
}

class _Sample {
  const _Sample(this.modified, this.dueAt);

  final DateTime? modified;
  final DateTime dueAt;
}
