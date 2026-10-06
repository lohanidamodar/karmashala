import 'dart:async';
import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/activity/activity_log.dart';
import 'package:karmashala_host/src/activity/server_activity.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart'
    show SessionLifecycleChange;
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'activity_fixture.dart';

void main() {
  late AppDatabase db;
  late DataService data;
  late StreamController<SessionStatusEntry> statuses;
  late StreamController<SessionLifecycleChange> lifecycle;
  late List<ActivityEntry> pushed;
  final now = DateTime.utc(2026, 10, 6, 12);
  const session = WatchedSession(
    key: AgentSessionKey('agentx', 'conv-1'),
    label: 'S1',
    openId: 's1',
    imported: false,
  );

  setUp(() async {
    db = activityStore();
    data = DataService(db, clock: () => now);
    statuses = StreamController.broadcast(sync: true);
    lifecycle = StreamController.broadcast(sync: true);
    pushed = [];
    data
        .open(
          (batch) => pushed.addAll(
            batch.changes.whereType<ActivityAppended>().expand(
              (c) => c.entries,
            ),
          ),
        )
        .handle(const DataSubscribe());
  });
  tearDown(() async {
    await statuses.close();
    await lifecycle.close();
    db.close();
  });

  ServerActivity start({String? settings}) => ServerActivity.start(
    data: data,
    statuses: statuses.stream,
    lifecycle: lifecycle.stream,
    settings: () => settings,
    clock: () => now,
    delay: const Duration(milliseconds: 1),
  );

  SessionStatusEntry status(AgentActivityStatus status) => SessionStatusEntry(
    session: session,
    report: AgentStatusReport(
      agentId: 'agentx',
      sessionId: 'conv-1',
      status: status,
      observedAt: now,
      source: AgentStatusSource.hook,
    ),
  );

  test('what the server sees is logged and pushed', () async {
    final activity = start();
    insertSession(db, 's1', at: now);
    statuses.add(status(AgentActivityStatus.working));
    statuses.add(status(AgentActivityStatus.idle));
    await activity.flushed;
    expect(pushed.map((e) => e.kind), [
      ActivityKind.sessionStarted,
      ActivityKind.turnStarted,
      ActivityKind.turnEnded,
    ]);
    await activity.close();
  });

  test('a usage limit filed in the inbox pauses, and a scheduled resume '
      'resumes', () async {
    final activity = start();
    insertSession(db, 's1', at: now);
    activity.inboxRaised(
      InboxItem(
        session: session,
        kind: InboxItemKind.usageLimit,
        at: now,
        detail: 'Limit resets at 14:00',
      ),
    );
    data.announce([
      DecisionRecorded(
        DecisionRecord(
          sessionId: 's1',
          kind: DecisionKind.approvalGranted,
          summary: 'Resumed',
          origin: DecisionOrigin.scheduledResume,
          recordedAt: now,
        ),
      ),
    ]);
    await activity.flushed;
    expect(
      pushed.where((e) => e.kind != ActivityKind.sessionStarted).map(
        (e) => (e.kind, e.detail),
      ),
      [
        (ActivityKind.limitPaused, 'Limit resets at 14:00'),
        (ActivityKind.limitResumed, null),
      ],
    );
    await activity.close();
  });

  group('retention', () {
    void seedOld() {
      insertSession(db, 'old', at: now.subtract(const Duration(days: 40)));
      insertSession(db, 'new', at: now.subtract(const Duration(days: 1)));
    }

    List<String> kept() =>
        ActivityLog(db).after(0).map((e) => e.sessionId).toList();

    test('everything is kept by default', () async {
      seedOld();
      final activity = start();
      activity.sweep();
      expect(kept(), ['old', 'new']);
      await activity.close();
    });

    test('a limit in days prunes what is older', () async {
      seedOld();
      final activity = start(
        settings: jsonEncode({kActivityLogKeepDaysSetting: 30}),
      );
      expect(activity.sweep(), 1);
      expect(kept(), ['new']);
      await activity.close();
    });

    test('a limit out of shape keeps everything', () {
      expect(activityKeepDays(jsonEncode({kActivityLogKeepDaysSetting: 'x'})),
          isNull);
      expect(activityKeepDays(jsonEncode({kActivityLogKeepDaysSetting: 0})),
          isNull);
      expect(activityKeepDays('not json'), isNull);
      expect(activityKeepDays(null), isNull);
      expect(activityKeepDays(jsonEncode({kActivityLogKeepDaysSetting: 90})),
          90);
    });
  });
}
