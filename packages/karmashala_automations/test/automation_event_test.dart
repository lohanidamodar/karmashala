import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/events.dart';
import 'package:test/test.dart';

/// The three rules that make an event automation safe to leave armed: a rule
/// never answers an event its own action caused, a burst is rate-limited, and
/// a dry run spends nothing.
void main() {
  final t0 = DateTime.utc(2026, 9, 21, 12);

  Automation rule({
    String id = 'r1',
    String repositoryId = 'repo',
    AutomationEventKind kind = AutomationEventKind.turnFinished,
    AutomationEventAction action = AutomationEventAction.messageSession,
    bool enabled = true,
  }) => Automation(
    id: id,
    repositoryId: repositoryId,
    name: 'Rule $id',
    schedule: AutomationSchedule.once(t0),
    agentInstallationId: '',
    prompt: 'run the tests',
    permissionMode: null,
    enabled: enabled,
    armedAt: t0,
    trigger: AutomationEventTrigger(kind: kind, action: action),
  );

  AutomationEvent event({
    DateTime? at,
    List<String> origin = const [],
    String repositoryId = 'repo',
    AutomationEventKind kind = AutomationEventKind.turnFinished,
  }) => AutomationEvent(
    kind: kind,
    sessionId: 's1',
    repositoryId: repositoryId,
    at: at ?? t0,
    origin: origin,
  );

  group('the origin chain', () {
    test('a rule already in the chain is skipped; one not in it fires', () {
      final verdicts = planAutomationEvent(
        rules: [
          rule(id: 'a'),
          rule(id: 'b'),
        ],
        event: event(origin: ['a']),
        limiter: AutomationRateLimiter(),
      );
      expect(verdicts.map((v) => v.outcome), [
        EventRuleOutcome.inOriginChain,
        EventRuleOutcome.fires,
      ]);
      // What the firing rule's action carries on: the chain, then itself.
      expect(verdicts.last.origin, ['a', 'b']);
    });

    test('a person-caused event reaches every matching rule', () {
      final verdicts = planAutomationEvent(
        rules: [rule(id: 'a')],
        event: event(),
        limiter: AutomationRateLimiter(),
      );
      expect(verdicts.single.fires, isTrue);
      expect(verdicts.single.origin, ['a']);
    });
  });

  group('the rate limit', () {
    test('a burst fires once per second per rule, then again after', () {
      final limiter = AutomationRateLimiter();
      final outcomes = [
        for (var ms = 0; ms < 1000; ms += 100)
          planAutomationEvent(
            rules: [rule()],
            event: event(at: t0.add(Duration(milliseconds: ms))),
            limiter: limiter,
          ).single.outcome,
      ];
      expect(outcomes.first, EventRuleOutcome.fires);
      expect(
        outcomes.skip(1),
        everyElement(EventRuleOutcome.rateLimited),
        reason: 'nine more inside the same second',
      );
      final later = planAutomationEvent(
        rules: [rule()],
        event: event(at: t0.add(const Duration(seconds: 1))),
        limiter: limiter,
      );
      expect(later.single.outcome, EventRuleOutcome.fires);
    });

    test('each rule has its own budget', () {
      final limiter = AutomationRateLimiter();
      planAutomationEvent(
        rules: [rule(id: 'a')],
        event: event(),
        limiter: limiter,
      );
      final verdicts = planAutomationEvent(
        rules: [
          rule(id: 'a'),
          rule(id: 'b'),
        ],
        event: event(at: t0.add(const Duration(milliseconds: 10))),
        limiter: limiter,
      );
      expect(verdicts.map((v) => v.outcome), [
        EventRuleOutcome.rateLimited,
        EventRuleOutcome.fires,
      ]);
    });
  });

  group('a dry run', () {
    test('spends none of the budget: the real event after it still fires', () {
      final limiter = AutomationRateLimiter();
      for (var i = 0; i < 3; i++) {
        final rehearsal = planAutomationEvent(
          rules: [rule()],
          event: event(),
          limiter: limiter,
          dryRun: true,
        );
        expect(rehearsal.single.outcome, EventRuleOutcome.fires);
      }
      expect(limiter.allows('r1', t0), isTrue);
      final real = planAutomationEvent(
        rules: [rule()],
        event: event(),
        limiter: limiter,
      );
      expect(real.single.outcome, EventRuleOutcome.fires);
      // The negative: the real one did spend, so the next is limited.
      expect(limiter.allows('r1', t0), isFalse);
    });

    test('still reports a rule the budget would stop', () {
      final limiter = AutomationRateLimiter()..record('r1', t0);
      final rehearsal = planAutomationEvent(
        rules: [rule()],
        event: event(),
        limiter: limiter,
        dryRun: true,
      );
      expect(rehearsal.single.outcome, EventRuleOutcome.rateLimited);
    });
  });

  test('the wrong event, another checkout, or paused never fires', () {
    final verdicts = planAutomationEvent(
      rules: [
        rule(id: 'kind', kind: AutomationEventKind.turnFailed),
        rule(id: 'elsewhere', repositoryId: 'other'),
        rule(id: 'paused', enabled: false),
        rule(id: 'ok'),
      ],
      event: event(),
      limiter: AutomationRateLimiter(),
    );
    expect(verdicts.map((v) => v.outcome), [
      EventRuleOutcome.otherEvent,
      EventRuleOutcome.otherCheckout,
      EventRuleOutcome.paused,
      EventRuleOutcome.fires,
    ]);
  });

  test('a time-based automation is not an event rule at all', () {
    final timed = Automation(
      id: 'nightly',
      repositoryId: 'repo',
      name: 'Nightly',
      schedule: const AutomationSchedule.cron('0 3 * * *'),
      agentInstallationId: 'a1',
      prompt: 'go',
      permissionMode: null,
      enabled: true,
      armedAt: t0,
    );
    expect(
      planAutomationEvent(
        rules: [timed],
        event: event(),
        limiter: AutomationRateLimiter(),
      ),
      isEmpty,
    );
  });

  group('needs you', () {
    AgentStatusReport report(
      AgentActivityStatus status, [
      AgentWaitKind waiting = AgentWaitKind.unrecorded,
    ]) => AgentStatusReport(
      agentId: 'claude-code',
      sessionId: 'c1',
      status: status,
      source: AgentStatusSource.hook,
      observedAt: t0,
      waiting: waiting,
    );

    AutomationEventKind? of(
      AgentActivityStatus? previous,
      AgentStatusReport now, {
      bool wasWaiting = false,
    }) => automationEventWithWait(previous, now, wasWaiting: wasWaiting);

    test('an approval or a question starts a wait on you', () {
      for (final kind in [AgentWaitKind.approval, AgentWaitKind.question]) {
        expect(
          of(
            AgentActivityStatus.working,
            report(AgentActivityStatus.awaitingApproval, kind),
          ),
          AutomationEventKind.needsYou,
        );
      }
    });

    test('an agent at its own input does not need you', () {
      for (final kind in [AgentWaitKind.input, AgentWaitKind.unrecorded]) {
        expect(
          of(
            AgentActivityStatus.working,
            report(AgentActivityStatus.awaitingApproval, kind),
          ),
          isNull,
        );
      }
    });

    test('one wait is one event, and a first sighting is none', () {
      final waiting = report(
        AgentActivityStatus.awaitingApproval,
        AgentWaitKind.approval,
      );
      expect(
        of(AgentActivityStatus.awaitingApproval, waiting, wasWaiting: true),
        isNull,
      );
      expect(of(null, waiting), isNull);
      // A wait whose kind is learnt late still counts once.
      expect(
        of(AgentActivityStatus.awaitingApproval, waiting),
        AutomationEventKind.needsYou,
      );
    });

    test('the turn events are unchanged', () {
      expect(
        of(AgentActivityStatus.working, report(AgentActivityStatus.idle)),
        AutomationEventKind.turnFinished,
      );
    });
  });

  test('a stored trigger from a newer build reads as none', () {
    expect(
      AutomationEventTrigger.fromRow(event: 'checks_failed', action: 'x'),
      isNull,
    );
    expect(
      AutomationEventTrigger.fromRow(
        event: 'turn_failed',
        action: 'start_session',
      ),
      const AutomationEventTrigger(
        kind: AutomationEventKind.turnFailed,
        action: AutomationEventAction.startSession,
      ),
    );
  });
}
