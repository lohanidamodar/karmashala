import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/automations/application/automation_event_router.dart';
import 'package:karmashala/src/features/automations/application/automation_scheduler.dart';
import 'package:karmashala/src/features/automations/application/usage_limit_watcher.dart';
import 'package:karmashala/src/features/notifications/application/session_status_registry.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/events.dart';
import 'package:karmashala_automations/persistence.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_notifications/watched.dart';

import '../../support/fixtures.dart';
import 'scheduled_resume_harness.dart';

/// Stands in for the runner: the queued row becomes a running one in a new
/// session, as a real launch would leave it. Starts no agent.
class _StartingFiring implements AutomationFiring {
  _StartingFiring(this._harness);

  final ResumeHarness _harness;
  final List<String> started = [];

  @override
  Future<void> fire(
    Automation automation,
    DateTime scheduledFor, {
    String note = '',
    AutomationRun? queued,
  }) async {
    final id = 'started-${started.length + 1}';
    started.add(id);
    SessionDao(_harness.db).insert(session(id: id, title: automation.name));
    AutomationDao(_harness.db).updateRun(
      queued!.copyWith(state: AutomationRunState.running, sessionId: id),
    );
  }
}

/// Event automations over the real router, DAO and send path: status changes
/// are emitted, the clock is moved by hand, and what reached a pane is read
/// back off it.
void main() {
  late ResumeHarness h;
  late StreamController<SessionStatusEntry> changes;
  late _StartingFiring firing;

  setUp(() async {
    changes = StreamController<SessionStatusEntry>.broadcast(sync: true);
    h = await ResumeHarness.create(
      extra: [
        sessionStatusChangesProvider.overrideWithValue(changes.stream),
        automationFiringProvider.overrideWith((ref) => firing),
      ],
    );
    firing = _StartingFiring(h);
    h.addSession();
    h.attachPane('s1');
    h.scheduler();
    h.container.listen(automationEventRouterProvider, (_, _) {});
  });

  tearDown(() async {
    await changes.close();
    await h.dispose();
  });

  AutomationDao dao() => AutomationDao(h.db);
  AutomationEventRouter router() =>
      h.container.read(automationEventRouterProvider.notifier);

  Automation rule({
    String id = 'rule',
    AutomationEventAction action = AutomationEventAction.messageSession,
    AutomationEventKind kind = AutomationEventKind.turnFinished,
  }) {
    final automation = Automation(
      id: id,
      repositoryId: 'r1',
      name: 'Rule $id',
      schedule: AutomationSchedule.once(h.now),
      agentInstallationId: action == AutomationEventAction.startSession
          ? 'a1'
          : '',
      prompt: 'run the tests',
      permissionMode: null,
      enabled: true,
      armedAt: h.now,
      trigger: AutomationEventTrigger(kind: kind, action: action),
    );
    dao().insert(automation);
    return automation;
  }

  SessionStatusEntry entry(
    String sessionId,
    AgentActivityStatus status, {
    AgentSessionEnding? ending,
  }) => SessionStatusEntry(
    session: WatchedSession(
      key: AgentSessionKey(AgentIds.codex, 'conv-$sessionId'),
      openId: sessionId,
      label: sessionId,
      imported: false,
    ),
    report: AgentStatusReport(
      agentId: AgentIds.codex,
      sessionId: 'conv-$sessionId',
      status: status,
      observedAt: h.now,
      source: AgentStatusSource.hook,
      ending: ending,
    ),
    sampledAt: h.now,
    lastProbedAt: null,
    probeFailed: false,
  );

  /// One turn: seen working, then seen ending as [end].
  Future<void> turn(
    String sessionId, {
    AgentActivityStatus end = AgentActivityStatus.idle,
  }) async {
    changes.add(entry(sessionId, AgentActivityStatus.working));
    changes.add(entry(sessionId, end));
    await h.settle();
  }

  int sends() => 'run the tests'.allMatches(h.typedInto('s1')).length;

  group('the origin chain', () {
    test(
      '"when a session finishes, send it a message" does not loop',
      () async {
        final automation = rule();

        await turn('s1');
        expect(sends(), 1, reason: 'the person-caused turn is answered');
        expect(
          h.typedInto('s1'),
          contains('Karmashala automation "Rule rule"'),
        );
        final first = dao().runsFor(automation.id).single;
        expect(first.state, AutomationRunState.finished);
        expect(first.origin, [automation.id]);
        expect(first.eventSessionId, 's1');

        // The turn the message caused. Well outside the rate limit, so only the
        // chain can be what stops it.
        h.clock.now = h.now.add(const Duration(minutes: 1));
        await turn('s1');
        expect(sends(), 1, reason: 'its own action caused this turn');
        expect(dao().runsFor(automation.id), hasLength(1));
        expect(
          dao().messagedOrigin('s1'),
          isEmpty,
          reason: 'the chain covers the one turn the message caused, no more',
        );

        // The negative: a turn the person causes next is answered again.
        h.clock.now = h.now.add(const Duration(minutes: 1));
        await turn('s1');
        expect(sends(), 2);
      },
    );

    test('a session a rule started never re-triggers that rule', () async {
      final automation = rule(action: AutomationEventAction.startSession);

      await turn('s1');
      expect(firing.started, ['started-1']);
      final run = dao().runsFor(automation.id).single;
      expect(run.sessionId, 'started-1');
      expect(run.origin, [automation.id]);

      // Its session settles, and then finishes a turn of its own.
      dao().updateRun(run.copyWith(state: AutomationRunState.finished));
      h.clock.now = h.now.add(const Duration(minutes: 1));
      await turn('started-1');
      expect(firing.started, ['started-1'], reason: 'no session begets one');

      // The negative: the person's own session still triggers it.
      h.clock.now = h.now.add(const Duration(minutes: 1));
      await turn('s1');
      expect(firing.started, ['started-1', 'started-2']);
    });

    test(
      'two rules feeding each other stop once both are in the chain',
      () async {
        final send = rule(id: 'send');
        final start = rule(
          id: 'start',
          action: AutomationEventAction.startSession,
        );

        await turn('s1');
        expect(sends(), 1);
        expect(firing.started, hasLength(1));
        dao().updateRun(
          dao()
              .runsFor(start.id)
              .single
              .copyWith(state: AutomationRunState.finished),
        );

        // s1's message-caused turn carries [send]: only "start" may answer it.
        h.clock.now = h.now.add(const Duration(minutes: 1));
        await turn('s1');
        expect(sends(), 1);
        expect(firing.started, hasLength(2));

        // The session that one started carries [send, start]: both are in its
        // chain, so neither answers its turn.
        final second = dao().runsFor(start.id).first;
        expect(second.origin, [send.id, start.id]);
        dao().updateRun(second.copyWith(state: AutomationRunState.finished));
        h.clock.now = h.now.add(const Duration(minutes: 1));
        await turn(second.sessionId!);
        expect(firing.started, hasLength(2), reason: 'the chain closed');
      },
    );
  });

  test('a burst of events is rate-limited per rule', () async {
    final automation = rule(action: AutomationEventAction.startSession);
    for (var i = 2; i <= 6; i++) {
      SessionDao(h.db).insert(session(id: 's$i', title: 'Other $i'));
    }
    // Five sessions finish within the same second.
    for (var i = 2; i <= 6; i++) {
      await turn('s$i');
      final run = dao().runsFor(automation.id).firstOrNull;
      // Settled at once, so the one-run-at-a-time guard is not what limits it.
      if (run != null && run.state.isLive) {
        dao().updateRun(run.copyWith(state: AutomationRunState.finished));
      }
      h.clock.now = h.now.add(const Duration(milliseconds: 100));
    }
    expect(firing.started, hasLength(1));

    h.clock.now = h.now.add(const Duration(seconds: 1));
    await turn('s2');
    expect(firing.started, hasLength(2), reason: 'the next second has room');
  });

  group('a dry run', () {
    test('fires nothing and spends none of the rate limit', () async {
      final automation = rule();
      final event = router().eventFor(AutomationEventKind.turnFinished, 's1')!;

      for (var i = 0; i < 3; i++) {
        final rehearsal = router().dryRun(event).single;
        expect(rehearsal.verdict.fires, isTrue);
        expect(rehearsal.action, 'Would send "run the tests" to "Work".');
        expect(rehearsal.refusal, isNull);
      }
      expect(sends(), 0, reason: 'nothing was typed');
      expect(dao().runsFor(automation.id), isEmpty, reason: 'nothing recorded');

      // The real event at the same instant still fires: nothing was spent.
      await turn('s1');
      expect(sends(), 1);
      final limited = router().dryRun(event).single;
      expect(limited.verdict.outcome, EventRuleOutcome.rateLimited);
    });

    test('does not spend a pending origin chain', () async {
      rule();
      dao().markMessaged('s1', ['rule'], h.now);
      final event = router().eventFor(AutomationEventKind.turnFinished, 's1')!;
      expect(event.origin, ['rule']);
      expect(
        router().dryRun(event).single.verdict.outcome,
        EventRuleOutcome.inOriginChain,
      );
      expect(dao().messagedOrigin('s1'), ['rule'], reason: 'still pending');
    });

    test('says when the message would be refused at fire time', () async {
      rule();
      h.statuses['s1'] = h.report('s1', status: AgentActivityStatus.working);
      final event = router().eventFor(AutomationEventKind.turnFinished, 's1')!;
      expect(router().dryRun(event).single.refusal, contains('working again'));
    });
  });

  group('what counts as the event', () {
    test('a SessionEnd (a /clear, a quit) is not a finished turn', () async {
      rule();
      changes.add(entry('s1', AgentActivityStatus.working));
      changes.add(
        entry(
          's1',
          AgentActivityStatus.idle,
          ending: AgentSessionEnding.completed,
        ),
      );
      await h.settle();
      expect(sends(), 0);
      // A /clear's ending leaves the row running, and is still not a turn.
      changes.add(entry('s1', AgentActivityStatus.working));
      changes.add(
        entry(
          's1',
          AgentActivityStatus.idle,
          ending: AgentSessionEnding.conversationOnly,
        ),
      );
      await h.settle();
      expect(sends(), 0);
      // The negative: the same move without the ending is one.
      h.clock.now = h.now.add(const Duration(minutes: 1));
      await turn('s1');
      expect(sends(), 1);
    });

    test('an idle session seen for the first time is not news', () async {
      rule();
      changes.add(entry('s1', AgentActivityStatus.idle));
      await h.settle();
      expect(sends(), 0);
    });

    test(
      'a failed turn answers only the rule listening for failures',
      () async {
        final failures = rule(id: 'fail', kind: AutomationEventKind.turnFailed);
        final finishes = rule(id: 'finish');
        await turn('s1', end: AgentActivityStatus.failed);
        expect(dao().runsFor(failures.id), hasLength(1));
        expect(dao().runsFor(finishes.id), isEmpty);
      },
    );

    test('an ended session is not restarted to take a message', () async {
      final automation = rule();
      SessionDao(h.db).updatePaneId('s1', null);
      await turn('s1');
      final run = dao().runsFor(automation.id).single;
      expect(run.state, AutomationRunState.missed);
      expect(run.reason, contains('never restarts'));
      expect(h.launcher.requests, isEmpty);
      expect(
        dao().messagedOrigin('s1'),
        isEmpty,
        reason: 'no message went in, so no turn is the rule\'s',
      );
    });
  });

  test('the clock never fires an event rule', () async {
    rule(action: AutomationEventAction.startSession);
    // The DAO stores no schedule for one; a row that has one anyway must still
    // be left to its event.
    h.db.execute(
      "UPDATE automations SET cron = '* * * * *' WHERE id = 'rule';",
    );
    final scheduler = h.scheduler();
    expect(h.timer.isArmed, isFalse, reason: 'nothing is due on a clock');
    h.clock.now = h.now.add(const Duration(days: 2));
    await scheduler.reconcile();
    expect(firing.started, isEmpty);
    expect(dao().runsFor('rule'), isEmpty);
  });
}
