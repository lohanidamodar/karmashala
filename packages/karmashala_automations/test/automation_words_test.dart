import 'package:karmashala_automations/automations.dart';
import 'package:test/test.dart';

/// What a person reads for an automation: never raw cron.
void main() {
  final now = DateTime(2026, 10, 7, 10);

  Automation automation({
    AutomationSchedule schedule = const AutomationSchedule.cron('0 9 * * 1-5'),
    AutomationEventTrigger? trigger,
    AutomationWebhook? webhook,
    AutomationSteps steps = AutomationSteps.standard,
    bool worktree = false,
    bool enabled = true,
  }) => Automation(
    id: 'a',
    repositoryId: 'r',
    name: 'Nightly',
    schedule: schedule,
    agentInstallationId: 'i',
    prompt: 'go',
    permissionMode: null,
    enabled: enabled,
    armedAt: now,
    trigger: trigger,
    webhook: webhook,
    steps: steps,
    worktree: worktree,
  );

  group('a schedule in words', () {
    test('the shapes the editor writes read exactly', () {
      expect(cronWords('0 9 * * 1-5'), 'Weekdays at 09:00');
      expect(cronWords('30 2 * * *'), 'Every day at 02:30');
      expect(cronWords('0 10 * * 0,6'), 'Weekends at 10:00');
      expect(cronWords('0 9 * * 1'), 'Mondays at 09:00');
      expect(cronWords('15 8 * * 1,3,5'), 'Mon, Wed and Fri at 08:15');
      expect(cronWords('0 * * * *'), 'Every hour, on the hour');
      expect(cronWords('*/15 * * * *'), 'Every 15 minutes');
    });

    test('anything else reads by when it next comes round', () {
      expect(
        cronWords('0 3 1 * *', now: now),
        'On a schedule of its own, next Sun 1 Nov at 03:00',
      );
      expect(cronWords('not cron'), 'A schedule this build cannot read');
    });

    test('the editor writes back what it reads', () {
      final week = timeOfWeekCron(cronForTimeOfWeek(7, 5, {1, 3, 5}))!;
      expect(week.hour, 7);
      expect(week.minute, 5);
      expect(week.days, {1, 3, 5});
      expect(cronForTimeOfWeek(9, 0, kWeekdays), '0 9 * * 1-5');
      expect(cronForTimeOfWeek(9, 0, kEveryDay), '0 9 * * *');
      expect(timeOfWeekCron('0 9 1 * *'), isNull);
    });

    test('an interval reads from the end of each run', () {
      expect(
        gapWords(const Duration(minutes: 90)),
        'Every 90 min after each run',
      );
      expect(
        gapWords(const Duration(hours: 2)),
        'Every 2 hours after each run',
      );
    });
  });

  group('the whole automation in one line', () {
    test('trigger, agent and steps, joined', () {
      final words = automationWords(
        automation(
          worktree: true,
          steps: AutomationSteps(const [
            AutomationStep(kind: AutomationStepKind.check),
            AutomationStep(
              kind: AutomationStepKind.tell,
              when: AutomationStepWhen.failure,
            ),
            AutomationStep(
              kind: AutomationStepKind.notify,
              when: AutomationStepWhen.always,
            ),
          ]),
        ),
        checkout: 'karmashala',
        agent: 'Claude Code',
      );
      expect(
        words,
        'Weekdays at 09:00, in karmashala → start Claude Code in a worktree → '
        'check the result → if it fails, tell the agent → always notify me',
      );
    });

    test('an event, a webhook and a notify-only rule', () {
      expect(
        automationWords(
          automation(
            trigger: const AutomationEventTrigger(
              kind: AutomationEventKind.turnFinished,
              action: AutomationEventAction.messageSession,
            ),
          ),
          checkout: 'app',
          agent: 'x',
        ),
        'When a session finishes a turn, in app → tell that session → check '
        'the result',
      );
      expect(
        automationWords(
          automation(
            webhook: const AutomationWebhook(hookId: 'h'),
            steps: AutomationSteps(const []),
          ),
          checkout: 'app',
          agent: 'Codex',
        ),
        'When its webhook URL is called (signed), in app → start Codex',
      );
      final notify = automation(
        trigger: const AutomationEventTrigger(
          kind: AutomationEventKind.turnFailed,
          action: AutomationEventAction.notifyOnly,
        ),
        steps: AutomationSteps(const [
          AutomationStep(
            kind: AutomationStepKind.notify,
            when: AutomationStepWhen.always,
          ),
        ]),
      );
      expect(notify.startsAgent, isFalse);
      expect(
        automationWords(notify, checkout: 'app', agent: 'x'),
        'When a session\'s turn fails, in app → start nothing → always '
        'notify me',
      );
    });

    test('a notify-only rule from a newer build reads as nothing to fire', () {
      expect(
        AutomationEventTrigger.fromRow(event: 'turn_failed', action: 'gone'),
        isNull,
      );
      expect(
        AutomationEventTrigger.fromRow(
          event: 'turn_failed',
          action: 'notify_only',
        )!.action,
        AutomationEventAction.notifyOnly,
      );
    });
  });

  group('the next run', () {
    test('in words, or why there is none', () {
      expect(nextRunWords(automation(), now: now), 'Weekdays at 09:00');
      expect(nextRunWords(automation(enabled: false), now: now), 'Paused');
      expect(
        nextRunWords(
          automation(webhook: const AutomationWebhook(hookId: 'h')),
          now: now,
        ),
        'Listening',
      );
      expect(
        nextRunWords(
          automation(
            trigger: const AutomationEventTrigger(
              kind: AutomationEventKind.turnFinished,
              action: AutomationEventAction.startSession,
            ),
          ),
          now: now,
        ),
        'On the next event',
      );
      expect(
        nextRunWords(
          automation(schedule: AutomationSchedule.once(DateTime(2026, 1, 1))),
          now: now,
        ),
        'Done',
      );
    });
  });
}
