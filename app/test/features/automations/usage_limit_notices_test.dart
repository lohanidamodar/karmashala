import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/automations/application/usage_limit_notices.dart';
import 'package:karmashala/src/features/sessions/application/session_notice.dart';
import 'package:karmashala_automations/resumes.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import 'scheduled_resume_harness.dart';

/// A usage limit the server noticed (slice 5c), shown in the session's bar:
/// the server detects it, files it and — as Settings says — offers, arms or
/// re-arms a resume; this app only says so, with the actions a person takes.
void main() {
  late ResumeHarness h;

  setUp(() async {
    h = await ResumeHarness.create();
    h.addSession();
    h.container.listen(usageLimitNoticesProvider, (_, _) {});
  });

  tearDown(() => h.dispose());

  UsageLimitNotice notice(
    UsageLimitOutcome outcome, {
    String? refusal,
    DateTime? resumeFireAt,
    String? resumeMessage,
  }) => UsageLimitNotice(
    sessionId: 's1',
    agentName: 'Codex CLI',
    windowLabel: '5-hour',
    resetsAt: h.now.add(const Duration(hours: 2)),
    outcome: outcome,
    refusal: refusal,
    resumeFireAt: resumeFireAt,
    resumeMessage: resumeMessage,
  );

  SessionNotice? bar() => h.container.read(sessionNoticesProvider)['s1'];

  Future<void> told(UsageLimitNotice notice) async {
    h.server.attention.usageLimit(notice);
    await h.settle();
  }

  test('an offer says the limit and offers a resume, arming nothing', () async {
    await told(notice(UsageLimitOutcome.offered));

    final posted = bar()!;
    expect(posted.message, startsWith('Codex CLI hit its 5-hour limit.'));
    expect(posted.message, contains('Resets'));
    expect(posted.sticky, isTrue);
    expect(posted.action?.label, 'Resume then');
    expect(posted.secondaryAction?.label, 'Options…');
    expect(h.live('s1'), isNull, reason: 'noticing arms nothing');
  });

  test('"Resume then" arms it through the server, with the defaults', () async {
    await told(notice(UsageLimitOutcome.offered));
    bar()!.action!.onPressed();
    await h.settle();

    final armed = h.live('s1')!;
    expect(armed.windowLabel, '5-hour');
    expect(armed.message, 'continue');
    expect(armed.scheduledBy, 'the user');
    expect(
      armed.fireAt,
      h.now.add(const Duration(hours: 2)).add(kResumeResetMargin),
    );
    expect(
      h.server.resumeRows.liveFor('s1'),
      isNotNull,
      reason: 'at the server',
    );
    expect(bar()!.message, contains('Resumes'));
    expect(bar()!.action?.label, 'Change…');
    expect(bar()!.secondaryAction?.label, 'Cancel');
  });

  test('"Options…" asks for the dialog, with the window named', () async {
    await told(notice(UsageLimitOutcome.offered));
    bar()!.secondaryAction!.onPressed();
    final request = h.container.read(resumeDialogRequestProvider)!;
    expect(request.sessionIds, ['s1']);
    expect(request.namedWindow, '5-hour');
  });

  test('armed by the setting, it says when and what it will send', () async {
    await told(
      notice(
        UsageLimitOutcome.scheduled,
        resumeFireAt: h.now.add(const Duration(hours: 2, seconds: 75)),
        resumeMessage: 'continue',
      ),
    );
    expect(bar()!.message, contains('Resumes'));
    expect(bar()!.message, contains('and sends "continue"'));
    expect(bar()!.message, isNot(contains('set up again')));
    expect(bar()!.action?.label, 'Change…');
  });

  test('armed again, it says why nobody was asked', () async {
    await told(
      notice(
        UsageLimitOutcome.renewed,
        resumeFireAt: h.now.add(const Duration(hours: 2)),
        resumeMessage: 'keep going',
      ),
    );
    expect(bar()!.message, contains('it was set up again'));
    expect(bar()!.message, contains('"keep going"'));
  });

  test('a refusal says why, and leaves only the options', () async {
    await told(notice(UsageLimitOutcome.refused, refusal: 'the mode prompts'));
    expect(
      bar()!.message,
      endsWith('A resume was not scheduled: the mode prompts'),
    );
    expect(bar()!.action?.label, 'Options…');
    expect(bar()!.secondaryAction, isNull);
  });

  test('the sentence names no reset it was not told', () {
    final sentence = usageLimitSentence(
      const UsageLimitNotice(
        sessionId: 's1',
        agentName: 'Claude Code',
        windowLabel: 'weekly',
        outcome: UsageLimitOutcome.offered,
      ),
      DateTime.utc(2026),
    );
    expect(sentence, 'Claude Code hit its weekly limit.');
  });
}
