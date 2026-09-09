import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/sessions/domain/session_launch.dart';
import 'package:flutter_test/flutter_test.dart';

AgentDescriptor _descriptor(String id) => AgentRegistry.builtIn.byId(id)!;

void main() {
  group('AgentForkSupport as declared data', () {
    test('defaults to unsupported, like allowsConcurrentResume', () {
      const spec = AgentLaunchSpec();
      expect(spec.fork.style, AgentForkStyle.unsupported);
      expect(spec.fork.isNative, isFalse);
      expect(spec.fork.argumentsFor('any-id'), isEmpty);
    });

    test('an unsupported fork contributes nothing, whatever the id', () {
      const fork = AgentForkSupport.unsupported();
      expect(fork.argumentsFor(''), isEmpty);
      expect(fork.argumentsFor('01a0-abcd'), isEmpty);
      expect(fork.evidence, isEmpty);
    });

    test('viaHandoff produces no arguments but does carry its evidence', () {
      const fork = AgentForkSupport.viaHandoff(evidence: 'checked --help');
      expect(fork.style, AgentForkStyle.viaHandoff);
      expect(fork.isNative, isFalse);
      expect(fork.argumentsFor('01a0-abcd'), isEmpty);
      expect(fork.evidence, 'checked --help');
    });

    test('a native fork with an empty id yields nothing to run', () {
      // The degraded case `SessionForkPlan` exists for: the capability is
      // there, the conversation has no name we can pass.
      const fork = AgentForkSupport.native(
        resume: AgentResume.subcommand('fork'),
        evidence: 'x',
      );
      expect(fork.argumentsFor(''), isEmpty);
    });
  });

  group('the shipped agents, against the installed CLIs', () {
    test('Claude Code forks by modifying a resume', () {
      final fork = _descriptor(AgentIds.claudeCode).launch.fork;
      expect(fork.style, AgentForkStyle.native);
      // `--fork-session` is documented as "use with --resume or --continue",
      // so the id still travels on the resume flag.
      expect(fork.argumentsFor('7f3a-1'), [
        '--resume',
        '7f3a-1',
        '--fork-session',
      ]);
      expect(fork.evidence, contains('--fork-session'));
    });

    test('Codex forks with a subcommand of its own, not with resume', () {
      final launch = _descriptor(AgentIds.codex).launch;
      expect(launch.fork.style, AgentForkStyle.native);
      expect(launch.fork.argumentsFor('01a0-9'), ['fork', '01a0-9']);
      // The distinction that matters: forking is not resuming, and the two
      // subcommands must never both appear.
      expect(launch.interactiveResume.argumentsFor('01a0-9'), [
        'resume',
        '01a0-9',
      ]);
      expect(launch.fork.evidence, contains('codex fork --help'));
    });

    test('Antigravity declares neither route', () {
      final descriptor = _descriptor(AgentIds.antigravity);
      expect(descriptor.launch.fork.style, AgentForkStyle.unsupported);
      // Not merely untested: it has no readable *transcript* to build a packet
      // from. The store is read now — identity, directory, name — but a handoff
      // packet is quoted from messages, and those stay protobuf, which is why
      // `antigravityStore` exists as a value distinct from the two transcript
      // formats.
      //
      // Delivery is no longer the blocker it was: `--prompt-interactive` can
      // carry a packet in. What is still missing is a packet to carry.
      expect(descriptor.store!.format, AgentStoreFormat.antigravityStore);
      expect(agentSupportsChatView(descriptor), isFalse);
    });

    test('every native fork states where it was verified', () {
      for (final descriptor in AgentRegistry.builtIn.descriptors) {
        if (!descriptor.launch.fork.isNative) continue;
        expect(
          descriptor.launch.fork.evidence,
          isNotEmpty,
          reason:
              '${descriptor.id} claims a native fork without saying what was '
              'checked. The claim has to be re-checkable against a future CLI.',
        );
      }
    });
  });

  group('values the real CLIs have retired', () {
    // Not a golden — a golden is what let this through twice. These are values
    // observed being *rejected* by an installed CLI, which is knowledge no
    // amount of comparing the descriptor to itself can produce.
    const retiredCodexApprovals = ['on-failure', 'untrusted'];

    test('no built-in descriptor passes a retired codex approval value', () {
      final support = _descriptor(AgentIds.codex).launch.permission;
      // Every selection the agent declares, rather than the three values of a
      // shared enum. The retired values lived on the approval axis, and the
      // whole axis — in every combination with the sandbox — is what has to be
      // swept for them now.
      for (final selection in support.selections()) {
        for (final retired in retiredCodexApprovals) {
          expect(
            support.argumentsFor(selection),
            isNot(contains(retired)),
            reason:
                'codex-cli rejects "$retired" outright and refuses to start, '
                'so ${selection.canonical} would make the agent unlaunchable '
                'rather than differently governed.',
          );
        }
      }
    });
  });
}
