import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/usage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/automations/application/scheduled_resume_providers.dart';
import 'package:karmashala_automations/resumes.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';

import 'scheduled_resume_harness.dart';

/// Scheduled resumes over fakes: armed through the server and kept honest
/// here until they come due. Firing one is the server's (slice 5c:
/// `server/test/automations/`); its scheduling rules are
/// `karmashala_automations`'. Nothing waits: the clock is moved and readiness
/// is an emitted report.
void main() {
  late ResumeHarness h;

  setUp(() async {
    h = await ResumeHarness.create();
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

    test('the server holds it once the write lands', () async {
      final resume = arm();
      await h.settle();
      expect(h.server.resumeRows.liveFor('s1')!.id, resume.id);
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
      h.server.sessionRows.updatePermissionMode('s1', null);
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
      h.observe();
      final resume = arm();
      await h.settle();
      h.clock.advance(const Duration(minutes: 10));
      h.usage.answer = h.reading(
        percent: 1,
        resetsIn: const Duration(hours: 5),
      );
      // Any surface's fetch: the observer only listens.
      h.usage.serverRead(h.server.installationRows.getById('a1')!);
      await h.settle();
      expect(h.dao.getById(resume.id)!.reason, contains('reset early'));
      expect(h.dao.getById(resume.id)!.fireAt, h.now);
    });

    test('a switched account is looked at again at once', () async {
      h.observe();
      h.usage.answer = h.reading();
      h.usage.serverRead(h.server.installationRows.getById('a1')!);
      final resume = arm();
      expect(resume.accountEmail, 'owner@example.com');
      await h.settle();

      h.clock.advance(const Duration(minutes: 10));
      h.usage.answer = h.reading(percent: 4, email: 'other@example.com');
      h.usage.serverRead(h.server.installationRows.getById('a1')!);
      await h.settle();
      expect(h.dao.getById(resume.id)!.reason, contains('account'));
    });

    test('an archived session is left alone', () async {
      arm();
      h.server.sessionRows.markArchived('s1', h.now);
      h.observe();
      await h.settle();
      expect(h.live('s1'), isNull);
    });
  });
}
