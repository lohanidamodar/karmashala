import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_session/launch.dart';
import 'package:test/test.dart';

AgentDescriptor _agent(String id) => AgentRegistry.builtIn.byId(id)!;

SessionForkPlan _plan(String agentId, {String? externalSessionId}) {
  final descriptor = AgentRegistry.builtIn.byId(agentId);
  return SessionForkPlan.decide(
    descriptor: descriptor,
    agentName: descriptor?.displayName ?? agentId,
    externalSessionId: externalSessionId,
  );
}

void main() {
  group('a capability is necessary and not sufficient', () {
    test('Claude Code forks natively when we know the conversation id', () {
      final plan = _plan(AgentIds.claudeCode, externalSessionId: '7f3a');
      expect(plan.kind, SessionForkKind.native);
      expect(plan.arguments, ['--resume', '7f3a', '--fork-session']);
      expect(plan.explanation, contains('Claude Code forks this itself'));
      expect(plan.explanation, contains('left exactly as it is'));
    });

    test('says it is the weaker of the two forks, and what stays behind', () {
      // A CLI's own in-session branch switches the running process into a
      // copy; this starts a second one from outside, and only the conversation
      // crosses. The dialog has to say which of the two the user is getting.
      final plan = _plan(AgentIds.claudeCode, externalSessionId: '7f3a');
      expect(plan.explanation, contains('It is a **new process**'));
      expect(plan.explanation, contains('not this session branching in place'));
      expect(plan.explanation, contains('only the conversation crosses'));
      expect(
        plan.explanation,
        contains('permissions granted for this session'),
      );
      expect(plan.explanation, contains('work already in flight'));
      expect(plan.explanation, contains('any link the CLI opened for it'));
      expect(
        plan.explanation,
        contains("Use Claude Code's own in-session branch command instead"),
      );
    });

    test('the sentence names the agent rather than one CLI\'s vocabulary', () {
      // Shown for every natively forking agent, so it states what is true of a
      // second process by construction instead of listing Claude's grants.
      final codex = _plan(AgentIds.codex, externalSessionId: '01a0-9');
      expect(codex.explanation, contains('It is a **new process**'));
      expect(
        codex.explanation,
        contains("Use Codex CLI's own in-session branch command instead"),
      );
    });

    test('Codex forks natively too, with its own subcommand', () {
      final plan = _plan(AgentIds.codex, externalSessionId: '01a0-9');
      expect(plan.kind, SessionForkKind.native);
      expect(plan.arguments, ['fork', '01a0-9']);
    });

    test('an agent that can fork but a session we cannot name degrades', () {
      // The live case: Codex will not accept a session id at launch, so a
      // native Codex row has none until something discovers it (Loop 46 §6).
      // `codex fork` with no id opens a picker that chooses by recency, which
      // would forge the one fact the user cares about — *which* conversation
      // they branched.
      final plan = _plan(AgentIds.codex);
      expect(plan.kind, SessionForkKind.handoff);
      expect(plan.arguments, isNull);
      expect(plan.explanation, contains('never learned its id for this one'));
      expect(plan.explanation, contains('hand off a written recap instead'));
    });

    test('an empty id is the same as no id', () {
      expect(
        _plan(AgentIds.claudeCode, externalSessionId: '').kind,
        SessionForkKind.handoff,
      );
    });
  });

  group('agents that cannot fork', () {
    test('viaHandoff says plainly that this will hand off instead', () {
      const descriptor = AgentDescriptor(
        id: 'someCli',
        displayName: 'Some CLI',
        binaries: AgentBinaries(windows: ['x'], posix: ['x']),
        launch: AgentLaunchSpec(
          fork: AgentForkSupport.viaHandoff(evidence: 'no fork in --help'),
        ),
      );
      final plan = SessionForkPlan.decide(
        descriptor: descriptor,
        agentName: 'Some CLI',
        externalSessionId: 'abc',
      );
      expect(plan.kind, SessionForkKind.handoff);
      expect(plan.explanation, contains('Some CLI cannot fork'));
      expect(plan.explanation, contains('this will hand off instead'));
      // The weakness is named, not glossed: the new session gets text, not the
      // agent's own record.
      expect(plan.explanation, contains('not Some CLI\'s own record'));
    });

    test('Antigravity is refused outright, and told why', () {
      final plan = _plan(AgentIds.antigravity);
      expect(plan.kind, SessionForkKind.refused);
      expect(plan.isRefused, isTrue);
      expect(plan.explanation, contains('no verified way to fork'));
      expect(plan.explanation, contains('none to carry one across'));
    });

    test('an agent with no descriptor at all is refused, never guessed at', () {
      final plan = SessionForkPlan.decide(
        descriptor: null,
        agentName: 'mystery',
        externalSessionId: 'abc',
      );
      expect(plan.kind, SessionForkKind.refused);
    });
  });

  test('every plan explains itself in words', () {
    for (final id in AgentIds.builtIn) {
      for (final externalId in [null, 'some-id']) {
        final plan = _plan(id, externalSessionId: externalId);
        expect(plan.explanation, isNotEmpty);
        // The explanation is shown *before* the fork, so it has to name the
        // agent rather than leaving the user to blame the app.
        expect(plan.explanation, contains(_agent(id).displayName));
      }
    }
  });
}
