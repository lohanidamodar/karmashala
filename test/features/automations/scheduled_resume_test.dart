import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/usage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/automations/application/scheduled_resume_providers.dart';
import 'package:karmashala_automations/persistence.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_automations/schedules.dart';
import 'package:karmashala_automations/resumes.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala_session/launch.dart';

import 'scheduled_resume_harness.dart';

/// Scheduled resumes end to end over fakes. Nothing here waits: the clock is
/// moved, the one timer is fired by hand and readiness is an emitted report.
void main() {
  late ResumeHarness h;

  setUp(() {
    h = ResumeHarness();
    h.addSession();
  });
  tearDown(() => h.dispose());

  UsageWindow fiveHour({
    double percent = 100,
    Duration resetsIn = const Duration(hours: 1),
  }) => UsageWindow(
    label: '5-hour',
    percent: percent,
    resetsAt: h.now.add(resetsIn),
    span: kUsageFiveHourWindow,
  );

  ScheduledResume arm({
    String sessionId = 's1',
    String message = 'continue',
    ResumeLatePolicy latePolicy = ResumeLatePolicy.ask,
    bool notify = false,
  }) => h.controller.schedule(
    ResumeRequest.atReset(
      sessionId: sessionId,
      window: fiveHour(),
      message: message,
      latePolicy: latePolicy,
      notify: notify,
    ),
  );

  /// Moves the clock to just past the row's moment and fires the one timer.
  Future<void> comeDue(ScheduledResume resume) async {
    h.clock.now = resume.fireAt.add(const Duration(seconds: 1));
    h.timer.fire();
    await h.settle();
  }

  group('arming', () {
    test('a resume waits for the reset plus the margin, and persists', () {
      final resume = arm();
      final stored = h.live('s1')!;
      expect(stored.id, resume.id);
      expect(stored.state, ScheduledResumeState.pending);
      expect(stored.windowLabel, '5-hour');
      expect(
        stored.fireAt,
        h.now.add(const Duration(hours: 1)).add(kResumeResetMargin),
      );
      expect(stored.accountKey, 'codex@windows');
      expect(stored.message, 'continue');
      expect(stored.liveWhenScheduled, isFalse);
    });

    test('scheduling again replaces the one that was waiting', () {
      final first = arm();
      final second = arm(message: 'carry on');
      expect(h.live('s1')!.id, second.id);
      final replaced = h.dao.getById(first.id)!;
      expect(replaced.state, ScheduledResumeState.cancelled);
      expect(replaced.reason, contains('Replaced'));
    });

    test('the scheduler arms its one timer for it', () async {
      h.scheduler();
      final resume = arm();
      await h.settle();
      expect(h.timer.armedFor, resume.fireAt.difference(h.now));
    });

    test('the last message is remembered for that agent', () {
      arm(message: 'keep going');
      expect(
        h.container
            .read(settingsControllerProvider)
            .resumeMessageFor(AgentIds.codex),
        'keep going',
      );
    });

    test('a mode that stops and asks is refused, in the gate\'s own words', () {
      SessionDao(h.db).updatePermissionMode('s1', null);
      expect(
        arm,
        throwsA(
          isA<ScheduledResumeRefused>().having(
            (refused) => refused.reason,
            'reason',
            allOf(contains('stops and asks'), contains('Codex')),
          ),
        ),
      );
      expect(h.live('s1'), isNull);
    });

    test('verification being off does not refuse a resume', () {
      expect(h.controller.refusalFor('s1'), isNull);
    });

    test('cancelling ends it and says who did', () {
      final resume = arm();
      expect(h.controller.cancelFor('s1'), isTrue);
      expect(h.live('s1'), isNull);
      expect(h.dao.getById(resume.id)!.reason, 'Cancelled by you.');
    });
  });

  group('firing', () {
    test('usage is re-read, and the session resumed with the message as its '
        'opening prompt — handed to the CLI once, never typed', () async {
      h.scheduler();
      final resume = arm(notify: true);
      h.usage.answer = h.reading(
        percent: 2,
        resetsIn: const Duration(hours: 5),
      );

      await comeDue(resume);
      expect(h.usage.calls, hasLength(1));
      final request = h.launcher.requests.single;
      expect(request.purpose, SessionPurpose.existingSession);
      expect(request.resumeExternalSessionId, 'conv-s1');
      expect(request.firstMessage, 'continue');
      // Nothing is typed at a TUI that is still starting.
      expect(h.typedInto('s1'), isEmpty);

      final done = h.dao.getById(resume.id)!;
      expect(done.state, ScheduledResumeState.done);
      expect(done.reason, contains('sent "continue"'));

      // A second tick finds nothing due: one fire, one message.
      h.timer.fire();
      await h.settle();
      expect(h.launcher.requests, hasLength(1));

      final decisions = h.container
          .read(decisionRecordDaoProvider)
          .forSession('s1');
      expect(decisions.single.summary, contains('sent "continue"'));
      expect(decisions.single.decidedBy, 'the user');
      expect(h.presenter.shown.single.title, 'Session resumed');
    });

    test('an empty message resumes and says nothing', () async {
      h.scheduler();
      final resume = arm(message: '');
      h.usage.answer = h.reading(percent: 2);
      await comeDue(resume);
      expect(h.launcher.requests.single.firstMessage, isNull);
      expect(h.typedInto('s1'), isEmpty);
      expect(h.dao.getById(resume.id)!.state, ScheduledResumeState.done);
    });

    test('a session already open is only told', () async {
      h.scheduler();
      h.attachPane('s1');
      final resume = arm();
      expect(resume.liveWhenScheduled, isTrue);
      h.usage.answer = h.reading(percent: 2);
      h.statuses['s1'] = h.report('s1');

      await comeDue(resume);
      expect(h.launcher.requests, isEmpty);
      expect(h.typedInto('s1'), startsWith('continue'));
      expect(h.typedInto('s1'), endsWith('\r'));
      expect('continue'.allMatches(h.typedInto('s1')), hasLength(1));
      expect(h.dao.getById(resume.id)!.reason, contains('already open'));
    });

    test(
      'an open session in a mode that asks is restarted in the armed one',
      () async {
        h.scheduler();
        SessionDao(h.db).updatePermissionMode('s1', null);
        h.attachPane('s1');
        const armed = 'approval=never;sandbox=danger-full-access';
        final resume = h.controller.schedule(
          ResumeRequest.atReset(
            sessionId: 's1',
            window: fiveHour(),
            permissionMode: armed,
          ),
        );
        h.usage.answer = h.reading(percent: 2);
        h.statuses['s1'] = h.report('s1');

        await comeDue(resume);
        final request = h.launcher.requests.single;
        expect(request.firstMessage, 'continue');
        expect(request.permissionOverride?.canonical, armed);
        expect(SessionDao(h.db).getById('s1')!.permissionMode, armed);
        expect(h.dao.getById(resume.id)!.state, ScheduledResumeState.done);
      },
    );

    test('an open prompt is never typed into', () async {
      h.scheduler();
      h.attachPane('s1');
      final resume = arm();
      h.usage.answer = h.reading(percent: 2);
      h.statuses['s1'] = h.report(
        's1',
        status: AgentActivityStatus.awaitingApproval,
        waiting: AgentWaitKind.approval,
      );
      await comeDue(resume);
      expect(h.typedInto('s1'), isEmpty);
      final failed = h.dao.getById(resume.id)!;
      expect(failed.state, ScheduledResumeState.failed);
      // A failure is announced whether or not the box was ticked.
      expect(h.presenter.shown.single.title, 'Scheduled resume failed');
    });

    test(
      'a launch that is refused fails the row in the launcher\'s words',
      () async {
        h.scheduler();
        final resume = arm();
        h.usage.answer = h.reading(percent: 2);
        h.launcher.failure = StateError('another process holds it');
        await comeDue(resume);
        final failed = h.dao.getById(resume.id)!;
        expect(failed.state, ScheduledResumeState.failed);
        expect(failed.reason, contains('another process holds it'));
      },
    );

    test('a resume resumed by hand in the meantime is cancelled', () async {
      h.scheduler();
      final resume = arm();
      h.attachPane('s1');
      h.usage.answer = h.reading(percent: 2);
      await comeDue(resume);
      expect(h.typedInto('s1'), isEmpty);
      final cancelled = h.dao.getById(resume.id)!;
      expect(cancelled.state, ScheduledResumeState.cancelled);
      expect(cancelled.reason, contains('resumed this session yourself'));
    });

    test('a time the user chose is not checked against usage', () async {
      h.scheduler();
      final resume = h.controller.schedule(
        ResumeRequest(
          sessionId: 's1',
          fireAt: h.now.add(const Duration(hours: 2)),
        ),
      );
      await comeDue(resume);
      expect(h.usage.calls, isEmpty);
      expect(h.launcher.requests, hasLength(1));
    });

    test(
      'a gate that lapsed since arming fails the fire, in its words',
      () async {
        h.scheduler();
        final resume = arm();
        SessionDao(h.db).updatePermissionMode('s1', null);
        await comeDue(resume);
        expect(h.launcher.requests, isEmpty);
        final failed = h.dao.getById(resume.id)!;
        expect(failed.state, ScheduledResumeState.failed);
        expect(failed.reason, contains('stops and asks'));
      },
    );
  });

  group('still limited', () {
    test(
      'the row moves to the new reset, and no request beats the floor',
      () async {
        h.scheduler();
        final resume = arm();
        h.usage.answer = h.reading(resetsIn: const Duration(hours: 2));
        await comeDue(resume);

        expect(h.launcher.requests, isEmpty);
        final moved = h.live('s1')!;
        expect(moved.state, ScheduledResumeState.pending);
        expect(moved.attempts, 1);
        expect(moved.reason, contains('Still limited'));
        expect(
          moved.fireAt,
          DateTime.utc(2026, 9, 17, 14).add(kResumeResetMargin),
        );
        // Re-armed for the new moment, off the same one timer.
        expect(h.timer.armedFor, moved.fireAt.difference(h.now));
        expect(h.usage.calls, hasLength(1));
      },
    );

    test('with no reset named it backs off, and keeps waiting rather than '
        'giving up', () async {
      h.scheduler();
      var resume = arm();
      for (var attempt = 1; attempt < 9; attempt++) {
        h.clock.now = resume.fireAt.add(const Duration(seconds: 1));
        h.usage.answer = AgentUsage(
          windows: [
            UsageWindow(
              label: '5-hour',
              percent: 100,
              resetsAt: h.now.subtract(const Duration(minutes: 1)),
              span: kUsageFiveHourWindow,
            ),
          ],
          fetchedAt: h.now,
        );
        h.timer.fire();
        await h.settle();
        resume = h.live('s1')!;
        expect(resume.attempts, attempt);
        final doubled = kResumeRetryBase * (1 << (attempt - 1));
        expect(
          resume.fireAt,
          h.now.add(
            doubled > kResumeRetryCeiling ? kResumeRetryCeiling : doubled,
          ),
        );
      }
      // Past where it used to give up, and still waiting: a limit that is
      // reached again is the case this row was armed for.
      expect(resume.attempts, greaterThan(kResumeMaxStaleReadings));
      expect(resume.state, ScheduledResumeState.pending);
      expect(resume.reason, contains('Still limited'));
      expect(h.launcher.requests, isEmpty);
      // And the wait never grows past the ceiling, so it is still looking.
      expect(
        resume.fireAt.difference(h.now),
        lessThanOrEqualTo(kResumeRetryCeiling),
      );
    });

    test('usage that cannot be re-read does not strand the resume', () async {
      h.scheduler();
      final resume = arm();
      h.usage.failure = UsageException('the network is down');
      await comeDue(resume);
      expect(h.launcher.requests, hasLength(1));
    });
  });

  group('after sleep or a restart', () {
    test('inside the grace it still runs', () async {
      final resume = arm();
      h.usage.answer = h.reading(percent: 2);
      h.clock.now = resume.fireAt.add(
        kMissedFireGrace - const Duration(minutes: 1),
      );
      h.scheduler();
      await h.settle();
      expect(h.launcher.requests, hasLength(1));
    });

    test(
      'beyond it the row is missed and says so, rather than running late',
      () async {
        final resume = arm();
        h.clock.now = resume.fireAt.add(const Duration(hours: 3));
        h.scheduler();
        await h.settle();
        expect(h.launcher.requests, isEmpty);
        final missed = h.dao.getById(resume.id)!;
        expect(missed.state, ScheduledResumeState.missed);
        expect(missed.reason, contains('3 hours ago'));
        expect(h.presenter.shown.single.title, 'Scheduled resume missed');
      },
    );

    test('unless its owner said to resume however late', () async {
      final resume = arm(latePolicy: ResumeLatePolicy.resume);
      h.usage.answer = h.reading(percent: 2);
      h.clock.now = resume.fireAt.add(const Duration(hours: 3));
      h.scheduler();
      await h.settle();
      expect(h.launcher.requests, hasLength(1));
    });
  });

  group('one unattended owner per checkout', () {
    void runAutomationInCheckout() {
      final automations = AutomationDao(h.db);
      automations.insert(
        Automation(
          id: 'auto1',
          repositoryId: 'r1',
          name: 'Nightly sweep',
          schedule: AutomationSchedule.once(h.now.add(const Duration(days: 9))),
          agentInstallationId: 'a1',
          prompt: 'Run the checks.',
          permissionMode: null,
          enabled: true,
          armedAt: h.now,
        ),
      );
      automations.insertRun(
        AutomationRun(
          id: 'run1',
          automationId: 'auto1',
          scheduledFor: h.now,
          firedAt: h.now,
          state: AutomationRunState.running,
          reason: '',
        ),
      );
    }

    test(
      'a busy checkout queues the resume with the reason, then drains',
      () async {
        final scheduler = h.scheduler();
        final resume = arm();
        runAutomationInCheckout();
        h.usage.answer = h.reading(percent: 2);
        await comeDue(resume);

        final queued = h.live('s1')!;
        expect(queued.state, ScheduledResumeState.queued);
        expect(queued.reason, contains('"Nightly sweep" is running there'));
        expect(h.launcher.requests, isEmpty);

        final automations = AutomationDao(h.db);
        automations.updateRun(
          automations
              .runById('run1')!
              .copyWith(state: AutomationRunState.finished),
        );
        await scheduler.drain('r1');
        await h.settle();
        expect(h.launcher.requests, hasLength(1));
      },
    );
  });

  group('between arming and firing', () {
    test('a session that carries on by itself lets the resume go', () async {
      h.attachPane('s1');
      arm();
      h.observe();
      await h.settle();
      h.reports.add(h.report('s1'));
      await h.settle();
      h.reports.add(h.report('s1', status: AgentActivityStatus.working));
      await h.settle();
      expect(h.live('s1'), isNull);
    });

    test('a window that reset early goes ahead now', () async {
      h.scheduler();
      h.observe();
      final resume = arm();
      await h.settle();
      h.clock.advance(const Duration(minutes: 10));
      h.usage.answer = h.reading(
        percent: 1,
        resetsIn: const Duration(hours: 5),
      );
      // Any surface's fetch: the observer only listens.
      await h.usage.fetch(AgentInstallationDao(h.db).getById('a1')!, const []);
      await h.settle();
      expect(h.dao.getById(resume.id)!.reason, contains('reset early'));
      h.timer.fire();
      await h.settle();
      expect(h.launcher.requests, hasLength(1));
    });

    test('a switched account is looked at again at once', () async {
      h.scheduler();
      h.observe();
      h.usage.answer = h.reading();
      await h.usage.fetch(AgentInstallationDao(h.db).getById('a1')!, const []);
      final resume = arm();
      expect(resume.accountEmail, 'owner@example.com');
      await h.settle();

      h.clock.advance(const Duration(minutes: 10));
      h.usage.answer = h.reading(percent: 4, email: 'other@example.com');
      await h.usage.fetch(AgentInstallationDao(h.db).getById('a1')!, const []);
      await h.settle();
      h.timer.fire();
      await h.settle();
      expect(h.launcher.requests, hasLength(1));
      h.reports.add(h.report('s1'));
      await h.settle();
      expect(h.dao.getById(resume.id)!.reason, contains('account'));
    });

    test('an archived session is left alone', () async {
      arm();
      SessionDao(h.db).markArchived('s1', h.now);
      h.observe();
      await h.settle();
      expect(h.live('s1'), isNull);
    });
  });
}
