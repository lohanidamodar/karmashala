import 'dart:async';
import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_notifications/attention.dart' show InboxItem, InboxItemKind;
import 'package:karmashala_session/events.dart' show DecisionOrigin;
import 'package:karmashala_session_engine/karmashala_session_engine.dart'
    show SessionLifecycleChange;

import '../data/data_service.dart';
import 'activity_recorder.dart';
import 'activity_writer.dart';

/// The `settings.v1` key Settings › Server › Storage writes: how many days of
/// the activity log to keep. Absent, zero or out of shape keeps everything.
const String kActivityLogKeepDaysSetting = 'activityLogKeepDays';

/// How often the activity log is swept for what has aged out.
const Duration kActivitySweepEvery = Duration(days: 1);

/// The days `settings.v1` ([raw]) keeps, or null for every day.
int? activityKeepDays(String? raw) {
  try {
    final decoded = raw == null ? null : jsonDecode(raw);
    if (decoded is Map) {
      final days = decoded[kActivityLogKeepDaysSetting];
      if (days is int && days > 0) return days;
    }
  } on FormatException {
    // Kept.
  }
  return null;
}

/// **The server's activity log, live**: what it sees — status moves, a
/// session ending, a usage limit and its resume — written off the turn and
/// pushed to every client, plus the rows the store's triggers write, and the
/// retention sweep.
class ServerActivity {
  ServerActivity._(this._data, this._writer, this._recorder, this._settings,
      this._clock);

  static ServerActivity start({
    required DataService data,
    required Stream<SessionStatusEntry> statuses,
    required Stream<SessionLifecycleChange> lifecycle,
    required String? Function() settings,
    DateTime Function()? clock,
    void Function(String message)? log,
    Duration delay = const Duration(milliseconds: 250),
  }) {
    final now = clock ?? () => DateTime.now().toUtc();
    final activity = data.activity;
    final writer = ActivityWriter(
      append: activity.append,
      tail: activity.after,
      lastId: activity.lastId,
      announce: (entries) => data.announce([ActivityAppended(entries)]),
      log: log,
      delay: delay,
    );
    final recorder = ActivityRecorder(
      record: writer.record,
      lastLogged: activity.latestKind,
      clock: now,
    );
    final server = ServerActivity._(data, writer, recorder, settings, now)
      .._subscriptions.addAll([
        statuses.listen(recorder.statusMoved),
        lifecycle.listen(recorder.lifecycleChanged),
      ]);
    data.addChangeListener(server._noticed);
    server._sweeps = Timer.periodic(kActivitySweepEvery, (_) => server.sweep());
    return server;
  }

  final DataService _data;
  final ActivityWriter _writer;
  final ActivityRecorder _recorder;
  final String? Function() _settings;
  final DateTime Function() _clock;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  Timer? _sweeps;

  /// Completes once what is queued now is written and told.
  Future<void> get flushed => _writer.flushed;

  /// An item filed in the server's inbox: a usage limit pauses its session.
  void inboxRaised(InboxItem item) {
    if (item.kind != InboxItemKind.usageLimit) return;
    _recorder.usageLimitHit(item.session.openId, item.detail ?? 'usage limit');
  }

  void _noticed(List<DataChange> changes) {
    var rows = false;
    for (final change in changes) {
      if (change is DecisionRecorded &&
          change.decision.origin == DecisionOrigin.scheduledResume) {
        _recorder.usageLimitResumed(change.decision.sessionId);
      }
      if (change is SessionDomainChange || change is RowRemoved) rows = true;
    }
    // A session row's own facts are written by the store's triggers.
    if (rows) _writer.nudge();
  }

  /// Prunes what the retention setting no longer keeps; answers how many.
  int sweep() {
    final days = activityKeepDays(_settings());
    if (days == null) return 0;
    try {
      return _data.activity.prune(_clock().subtract(Duration(days: days)));
    } on Object {
      return 0;
    }
  }

  Future<void> close() async {
    _sweeps?.cancel();
    _data.removeChangeListener(_noticed);
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _writer.close();
  }
}
