import 'dart:async';
import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/cleanup.dart';

import '../data/data_service.dart';
import 'worktree_cleanup_service.dart';

/// **Worktree cleanup, kept by the server**: the setting a person wrote (a
/// preference), sweeps — one at a time, the schedule's and a client's alike —
/// and the removal log and last sweep, which only the server writes and
/// every client is told of ([WorktreeCleanupChanged]).
///
/// The schedule runs with no client connected: every
/// [kWorktreeCleanupInterval] once anything is turned on, never before
/// [kWorktreeCleanupSettleAfterLaunch] after the server started nor
/// [kWorktreeCleanupSettleAfterChange] after the setting changed.
class WorktreeCleanup {
  WorktreeCleanup({
    required this.data,
    required this.service,
    DateTime Function()? clock,
    this.onItsOwn = true,
  }) : _now = clock ?? _utcNow,
       _availableSince = (clock ?? _utcNow)();

  final DataService data;
  final WorktreeCleanupService service;
  final DateTime Function() _now;

  /// Whether sweeps run on the schedule; off, only when a client asks.
  final bool onItsOwn;

  static DateTime _utcNow() => DateTime.now().toUtc();

  /// Entries kept in the log; the oldest fall off.
  static const int logLimit = 200;

  final DateTime _availableSince;
  Timer? _timer;
  Future<WorktreeCleanupReport>? _inFlight;
  var _stopped = false;

  bool get isSweeping => _inFlight != null;

  WorktreeCleanupSettings get settings =>
      WorktreeCleanupSettings.fromJson(_decode(WorktreeCleanupKeys.settings));

  /// The removal log, newest first, and the last sweep.
  WorktreeCleanupLog get log => WorktreeCleanupLog(
    entries: [
      if (_decode(WorktreeCleanupKeys.log) case final List<Object?> entries)
        for (final entry in entries) ?WorktreeCleanupLogEntry.fromJson(entry),
    ],
    lastSweep: WorktreeCleanupSweepSummary.fromJson(
      _decode(WorktreeCleanupKeys.lastSweep),
    ),
  );

  /// Arms the schedule, and re-arms it whenever the setting changes.
  void start() {
    data.addChangeListener(_noticed);
    _arm();
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    data.removeChangeListener(_noticed);
  }

  /// A dry run: removes nothing, writes nothing.
  Future<WorktreeCleanupReport> preview() => service.preview(settings);

  /// A real sweep under the current setting, or the one already running.
  Future<WorktreeCleanupReport> sweep({required bool automatic}) {
    final running = _inFlight;
    if (running != null) return running;
    final future = _sweep(automatic);
    _inFlight = future;
    return future.whenComplete(() {
      _inFlight = null;
      _arm();
    });
  }

  /// Files one removal attempt in the log.
  void record(WorktreeCleanupLogEntry entry) {
    final next = [entry, ...log.entries].take(logLimit);
    data.setServerValue(
      WorktreeCleanupKeys.log,
      jsonEncode([for (final e in next) e.toJson()]),
    );
  }

  /// When the automatic sweep is next due, or null when nothing is on.
  DateTime? nextDue() {
    final current = settings;
    if (!current.anyEnabled) return null;
    final floors = [
      _availableSince.add(kWorktreeCleanupSettleAfterLaunch),
      if (current.changedAt != null)
        current.changedAt!.add(kWorktreeCleanupSettleAfterChange),
      if (log.lastSweep case final last?)
        last.startedAt.add(kWorktreeCleanupInterval),
    ];
    return floors.reduce((a, b) => a.isAfter(b) ? a : b);
  }

  Future<WorktreeCleanupReport> _sweep(bool automatic) async {
    final started = _now();
    // Recorded first, so the next due time moves on even if this one throws.
    _saveLastSweep(
      WorktreeCleanupSweepSummary(startedAt: started, automatic: automatic),
    );
    try {
      final report = await service.sweep(settings, automatic: automatic);
      _saveLastSweep(
        WorktreeCleanupSweepSummary(
          startedAt: started,
          finishedAt: _now(),
          automatic: automatic,
          removed: report.withOutcome(WorktreeCleanupOutcome.removed).length,
          kept: report.withOutcome(WorktreeCleanupOutcome.kept).length,
          failed: report.withOutcome(WorktreeCleanupOutcome.failed).length,
        ),
      );
      return report;
    } catch (error) {
      _saveLastSweep(
        WorktreeCleanupSweepSummary(
          startedAt: started,
          finishedAt: _now(),
          automatic: automatic,
          error: '$error',
        ),
      );
      rethrow;
    } finally {
      data.announce([WorktreeCleanupChanged(log)]);
    }
  }

  void _saveLastSweep(WorktreeCleanupSweepSummary summary) => data
      .setServerValue(WorktreeCleanupKeys.lastSweep, jsonEncode(summary.toJson()));

  void _noticed(List<DataChange> changes) {
    for (final change in changes) {
      if (change case PreferenceChanged(key: WorktreeCleanupKeys.settings)) {
        _arm();
        return;
      }
    }
  }

  /// Arms the timer for the next due moment, or disarms it. A long wait is
  /// taken in steps, so a clock that jumps is caught up with.
  void _arm() {
    _timer?.cancel();
    _timer = null;
    if (_stopped || !onItsOwn) return;
    final due = nextDue();
    if (due == null) return;
    var delay = due.difference(_now());
    if (delay.isNegative) delay = Duration.zero;
    const step = Duration(hours: 1);
    _timer = Timer(delay > step ? step : delay, () {
      final now = _now();
      final at = nextDue();
      if (at != null && !at.isAfter(now) && !isSweeping) {
        unawaited(sweep(automatic: true).then((_) {}, onError: (Object _) {}));
        return;
      }
      _arm();
    });
  }

  Object? _decode(String key) {
    final raw = data.serverValue(key);
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }
}
