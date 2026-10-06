
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/activity/activity_log.dart';
import 'package:karmashala_host/src/activity/activity_recorder.dart';
import 'package:karmashala_host/src/activity/activity_writer.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_session/session.dart' show SessionStatus;
import 'package:karmashala_session_engine/karmashala_session_engine.dart'
    show SessionLifecycleChange;
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'activity_fixture.dart';

void main() {
  final t0 = DateTime.utc(2026, 10, 6, 9);

  group('ActivityWriter', () {
    late AppDatabase db;
    late ActivityLog log;
    late List<List<ActivityEntry>> told;
    late List<String> logged;

    setUp(() {
      db = activityStore();
      log = ActivityLog(db);
      told = [];
      logged = [];
    });
    tearDown(() => db.close());

    ActivityWriter writerOver({
      List<ActivityEntry> Function(List<ActivityDraft>)? append,
    }) => ActivityWriter(
      append: append ?? log.append,
      tail: log.after,
      lastId: log.lastId,
      announce: told.add,
      log: logged.add,
      delay: const Duration(milliseconds: 5),
    );

    test('drafts are batched into one write and pushed as appended', () async {
      final writer = writerOver();
      insertSession(db, 's1', at: t0);
      for (var i = 0; i < 3; i++) {
        writer.record(
          ActivityDraft(
            at: t0.add(Duration(minutes: i)),
            kind: ActivityKind.turnStarted,
            sessionId: 's1',
          ),
        );
      }
      await writer.flushed;
      // The row's own start, which the trigger wrote, is pushed with them.
      expect(told, hasLength(1));
      expect(told.single.map((e) => e.kind), [
        ActivityKind.sessionStarted,
        ActivityKind.turnStarted,
        ActivityKind.turnStarted,
        ActivityKind.turnStarted,
      ]);
      await writer.close();
    });

    test('rows the store wrote itself are pushed on a nudge', () async {
      final writer = writerOver();
      insertSession(db, 's1', at: t0);
      writer.nudge();
      await writer.flushed;
      expect(told.single.single.kind, ActivityKind.sessionStarted);
      writer.nudge();
      await writer.flushed;
      expect(told, hasLength(1), reason: 'nothing new, nothing told');
      await writer.close();
    });

    test('a turn is never slowed or failed by a failing log write', () async {
      var calls = 0;
      final writer = writerOver(
        append: (drafts) {
          calls++;
          throw StateError('disk full');
        },
      );
      final watch = Stopwatch()..start();
      writer.record(
        ActivityDraft(at: t0, kind: ActivityKind.turnStarted, sessionId: 's1'),
      );
      watch.stop();
      expect(calls, 0, reason: 'nothing is written on the caller\'s turn');
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 50)));
      await writer.flushed;
      expect(calls, 1);
      expect(logged.single, contains('1 activity entries not written'));
      expect(logged.single, contains('disk full'));
      // The next write still goes through.
      await writer.close();
    });

    test('closing writes what is queued', () async {
      insertSession(db, 's1', at: t0);
      final writer = writerOver();
      writer.record(
        ActivityDraft(at: t0, kind: ActivityKind.turnEnded, sessionId: 's1'),
      );
      await writer.close();
      expect(
        log.after(0).map((e) => e.kind),
        [ActivityKind.sessionStarted, ActivityKind.turnEnded],
      );
    });
  });

  group('ActivityRecorder', () {
    late List<ActivityDraft> drafts;
    late Map<String, ActivityKind> lastLogged;
    var now = t0;

    setUp(() {
      drafts = [];
      lastLogged = {};
      now = t0;
    });

    ActivityRecorder recorder() => ActivityRecorder(
      record: drafts.add,
      lastLogged: (id) => lastLogged[id],
      clock: () => now,
    );

    SessionStatusEntry status(
      AgentActivityStatus status, {
      DateTime? waitingSince,
      AgentToolAsk? ask,
      List<String> evidence = const [],
      String? failureReason,
    }) => SessionStatusEntry(
      session: const WatchedSession(
        key: AgentSessionKey('agentx', 'conv-1'),
        label: 'S1',
        openId: 's1',
        imported: false,
      ),
      report: AgentStatusReport(
        agentId: 'agentx',
        sessionId: 'conv-1',
        status: status,
        observedAt: now,
        source: AgentStatusSource.hook,
        waitingSince: waitingSince,
        toolAsk: ask,
        evidence: evidence,
        failureReason: failureReason,
      ),
    );

    test('a turn with a wait in it is four edges, waits timed from the ask',
        () {
      final r = recorder();
      r.statusMoved(status(AgentActivityStatus.idle));
      now = t0.add(const Duration(minutes: 1));
      r.statusMoved(status(AgentActivityStatus.working));
      now = t0.add(const Duration(minutes: 3));
      r.statusMoved(
        status(
          AgentActivityStatus.awaitingApproval,
          waitingSince: t0.add(const Duration(minutes: 2)),
          ask: AgentToolAsk(
            toolName: 'Write',
            input: const {'file_path': 'app/lib/main.dart'},
            at: t0,
          ),
        ),
      );
      now = t0.add(const Duration(minutes: 15));
      r.statusMoved(status(AgentActivityStatus.working));
      r.statusMoved(status(AgentActivityStatus.working));
      now = t0.add(const Duration(minutes: 20));
      r.statusMoved(status(AgentActivityStatus.idle));

      expect(drafts.map((d) => (d.kind, d.at)), [
        (ActivityKind.turnStarted, t0.add(const Duration(minutes: 1))),
        (ActivityKind.waitBegan, t0.add(const Duration(minutes: 2))),
        (ActivityKind.waitEnded, t0.add(const Duration(minutes: 15))),
        (ActivityKind.turnEnded, t0.add(const Duration(minutes: 20))),
      ]);
      expect(drafts[1].detail, 'Write app/lib/main.dart');
      expect(drafts.every((d) => d.sessionId == 's1'), isTrue);
    });

    test('a wait with no ask is described by the agent\'s own words', () {
      final r = recorder();
      r.statusMoved(
        status(
          AgentActivityStatus.awaitingApproval,
          evidence: const ['Do you want to proceed?', 'more'],
        ),
      );
      expect(drafts.map((d) => d.kind), [
        ActivityKind.turnStarted,
        ActivityKind.waitBegan,
      ]);
      expect(drafts.last.detail, 'Do you want to proceed?');
    });

    test('a failed turn ends the turn with its reason; unknown is no edge', () {
      final r = recorder();
      r.statusMoved(status(AgentActivityStatus.working));
      r.statusMoved(status(AgentActivityStatus.unknown));
      r.statusMoved(
        status(AgentActivityStatus.failed, failureReason: 'rate_limit'),
      );
      expect(drafts.map((d) => d.kind), [
        ActivityKind.turnStarted,
        ActivityKind.turnEnded,
      ]);
      expect(drafts.last.detail, 'failed: rate_limit');
    });

    test('first sight after a restart neither repeats an open turn nor '
        'leaves a cut-off one open', () {
      lastLogged['s1'] = ActivityKind.turnStarted;
      final r = recorder();
      r.statusMoved(status(AgentActivityStatus.working));
      expect(drafts, isEmpty, reason: 'the turn is already open in the log');

      final again = recorder();
      again.statusMoved(status(AgentActivityStatus.idle));
      expect(drafts.single.kind, ActivityKind.turnEnded);
      expect(drafts.single.approximate, isTrue);
    });

    test('a session ending is told by its lifecycle', () {
      recorder().lifecycleChanged(
        const SessionLifecycleChange(
          sessionId: 's1',
          from: SessionStatus.running,
          to: SessionStatus.failed,
        ),
      );
      recorder().lifecycleChanged(
        const SessionLifecycleChange(
          sessionId: 's2',
          from: SessionStatus.created,
          to: SessionStatus.running,
        ),
      );
      expect(drafts.single.kind, ActivityKind.sessionEnded);
      expect(drafts.single.detail, 'failed');
    });

    test('a usage limit pauses and a resume resumes', () {
      final r = recorder();
      r.usageLimitHit('s1', 'Limit resets at 14:00');
      r.usageLimitResumed('s1');
      expect(drafts.map((d) => (d.kind, d.detail)), [
        (ActivityKind.limitPaused, 'Limit resets at 14:00'),
        (ActivityKind.limitResumed, null),
      ]);
    });
  });

  test('flushed completes at once when nothing is queued', () async {
    final db = activityStore();
    final log = ActivityLog(db);
    final writer = ActivityWriter(
      append: log.append,
      tail: log.after,
      lastId: log.lastId,
      announce: (_) {},
    );
    await writer.flushed.timeout(const Duration(seconds: 1));
    await writer.close();
    db.close();
  });

  test('latestKind reads the newest entry of a session', () {
    final db = activityStore();
    insertSession(db, 's1', at: t0);
    expect(ActivityLog(db).latestKind('s1'), ActivityKind.sessionStarted);
    expect(ActivityLog(db).latestKind('nope'), isNull);
    db.close();
  });

}
