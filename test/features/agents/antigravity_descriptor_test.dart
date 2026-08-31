import 'package:chitragupta/src/features/agents/domain/agent_descriptor.dart';
import 'package:chitragupta/src/features/agents/domain/agent_ids.dart';
import 'package:chitragupta/src/features/agents/domain/agent_registry.dart';
import 'package:chitragupta/src/features/agents/domain/permission_carry.dart';
import 'package:chitragupta/src/features/cli_detection/domain/agent_command_line.dart';
import 'package:chitragupta/src/features/sessions/domain/session_fork.dart';
import 'package:chitragupta/src/features/sessions/domain/session_launch.dart';
import 'package:chitragupta/src/features/settings/domain/permission_mode.dart';
import 'package:chitragupta/src/features/terminal/domain/agent_pane_launch.dart';
import 'package:flutter_test/flutter_test.dart';

/// What Chitragupta is allowed to claim about Antigravity.
///
/// Every agent fact in this repo carries the `--help` output it was read from,
/// and Antigravity was the exception: Loop 10 shipped its adapter against a
/// fake process and recorded "no real CLI", and everything downstream inherited
/// that. `docs/ANTIGRAVITY_SUPPORT_2026-08-31.md` records what interrogating a
/// real installation produced.
///
/// The load-bearing discovery is in the first test. The CLI is `agy`; nothing
/// is installed under the name the registry had been probing for, which is why
/// none of the rest of this had ever run against anything.
void main() {
  const registry = AgentRegistry.builtIn;
  final descriptor = registry.byId(AgentIds.antigravity)!;

  group('the executable', () {
    test('is agy, the name the CLI installs itself under', () {
      expect(descriptor.binaries.windows, ['agy']);
      expect(descriptor.binaries.posix, ['agy']);
    });

    test('an agy command line is recognised as this agent', () {
      // `agentIdForCommandLine` reads the registry, so adopting a session the
      // user started in their own terminal depends on the name above being
      // right. Under the old name none of these matched anything.
      for (final line in [
        'agy',
        'agy --continue',
        '/home/me/.local/bin/agy --conversation 53161419',
        r'C:\Users\me\AppData\Local\agy\bin\agy.exe',
      ]) {
        expect(
          agentIdForCommandLine(line, registry),
          AgentIds.antigravity,
          reason: line,
        );
      }
    });
  });

  group('permission modes, all three read off agy --help', () {
    test('every mode maps, and maps exactly', () {
      final launch = descriptor.launch;
      expect(launch.expressiblePermissionModes, PermissionMode.values);
      for (final mode in PermissionMode.values) {
        expect(
          launch.permissionFitFor(mode),
          PermissionModeFit.exact,
          reason: mode.name,
        );
      }
    });

    test('ask is the unflagged default, and says so', () {
      // The one empty argument list in this descriptor that is *exact* rather
      // than absent: `--dangerously-skip-permissions` is documented as the way
      // to stop the CLI prompting, so prompting is what it does unflagged.
      expect(
        descriptor.launch.permissionArgumentsFor(PermissionMode.ask),
        isEmpty,
      );
      expect(descriptor.launch.permissionNoteFor(PermissionMode.ask), isNotNull);
    });

    test('accept-edits and bypass name the documented flags', () {
      expect(descriptor.launch.permissionArgumentsFor(PermissionMode.acceptEdits), [
        '--mode',
        'accept-edits',
      ]);
      expect(descriptor.launch.permissionArgumentsFor(PermissionMode.bypass), [
        '--dangerously-skip-permissions',
      ]);
    });

    test('the invented flags are gone from every mode', () {
      // `--yolo` was the only mode this agent claimed to support and is not a
      // flag the CLI has, so the single mode it offered was the one that would
      // have failed — and it was the dangerous one.
      for (final mode in PermissionMode.values) {
        expect(
          descriptor.launch.permissionArgumentsFor(mode),
          isNot(contains('--yolo')),
        );
      }
      expect(descriptor.launch.baseArguments, isNot(contains('--stdio')));
    });
  });

  group('resume', () {
    test('names the conversation by id, in both launch styles', () {
      expect(descriptor.launch.resume.argumentsFor('c1'), [
        '--conversation',
        'c1',
      ]);
      // The entry that was missing rather than wrong: `interactiveResume` was
      // left unset, so a pane could never continue an Antigravity conversation
      // whatever the rest of the registry said.
      expect(descriptor.launch.interactiveResume.argumentsFor('c1'), [
        '--conversation',
        'c1',
      ]);
    });

    test('a pane resumes with the permission flags beside it', () {
      // What `interactiveAgentArguments` actually builds — the path a terminal
      // session takes, as opposed to the adapter's.
      expect(
        interactiveAgentArguments(
          descriptor,
          PermissionMode.acceptEdits,
          resumeSessionId: 'c1',
        ),
        ['--mode', 'accept-edits', '--conversation', 'c1'],
      );
    });

    test('a new session under the safe mode is launched bare', () {
      expect(
        interactiveAgentArguments(descriptor, PermissionMode.ask),
        isEmpty,
      );
    });
  });

  group('the store is located, and known to be unreadable', () {
    test('it is the CLI data dir, not the IDE extensions dir', () {
      // `.antigravity` is the IDE's VS Code-style extensions directory. The CLI
      // writes `~/.gemini/antigravity-cli`, beside the IDE's `antigravity-ide`.
      expect(descriptor.store!.homeDirectoryName, '.gemini/antigravity-cli');
    });

    test('the format records that nothing here can parse it', () {
      // Encrypted on the older build; SQLite full of opaque protobuf blobs on
      // the current one. Knowing where the conversations are and knowing we
      // cannot read them are two different facts.
      expect(descriptor.store!.format, AgentStoreFormat.none);
    });

    test('locating the store does not conjure a chat view', () {
      expect(agentSupportsChatView(descriptor), isFalse);
      expect(defaultViewFor(descriptor), SessionView.terminal);
    });
  });

  group('what is still unverified stays unoffered', () {
    test('no status can be reported, because none was ever observed', () {
      // No hook config, no parseable state file, and the TUI was never watched,
      // so there is no screen text to match on. `unknown` is the honest answer.
      expect(descriptor.statusStrategy, AgentStatusStrategy.none);
      expect(descriptor.grid.isEmpty, isTrue);
      expect(descriptor.stateFile, isNull);
      expect(descriptor.hooks, isNull);
    });

    test('no approval keys, because the file that named them is gone', () {
      // The 1.0.13 build wrote a keybindings.json binding `confirm.yes` to `y`
      // and `confirm.no` to `n`. 1.1.22 ships no such file, so those keys
      // describe a version nobody runs — and pressing a guessed key into a TUI
      // is the one failure worse than sending the user to the terminal.
      expect(descriptor.approval.isEmpty, isTrue);
    });

    test('no opening prompt is passed as a positional argument', () {
      // A real distinction rather than caution: the CLI takes an opening prompt
      // as `-i` / `--prompt-interactive <prompt>`, a flag with a value, not the
      // trailing positional this field means.
      expect(descriptor.launch.acceptsPromptArgument, isFalse);
    });

    test('concurrent resume is not claimed', () {
      // Never tested against this CLI, and the safe answer is the default:
      // being wrong permissively means two processes on one conversation.
      expect(descriptor.launch.allowsConcurrentResume, isFalse);
    });

    test('forking is refused, and the refusal explains both closed routes', () {
      final plan = SessionForkPlan.decide(
        descriptor: descriptor,
        agentName: descriptor.displayName,
        externalSessionId: 'c1',
      );
      // `agy --help` lists every subcommand it has and none of them forks; the
      // handoff route is closed too, because a packet is quoted from a
      // transcript and this agent's are unreadable.
      expect(plan.kind, SessionForkKind.refused);
      expect(plan.explanation, contains('no verified way'));
    });
  });

  group('the permission-carry rule still holds', () {
    test('a careful session handed here is enforced, not escalated', () {
      // Antigravity used to be the agent this rule was written against, as the
      // one whose only expressible mode was bypass. Now that `ask` maps
      // exactly, the carry is better than a fallback — but it must still never
      // arrive at bypass.
      final carried = carryPermission(PermissionMode.ask, descriptor);
      expect(carried.mode, PermissionMode.ask);
      expect(carried.fit, PermissionModeFit.exact);
      expect(carried.enforced, isTrue);
      expect(carried.changed, isFalse);
    });

    test('a bypass session is not silently made safer or more dangerous', () {
      final carried = carryPermission(PermissionMode.bypass, descriptor);
      expect(carried.mode, PermissionMode.bypass);
      expect(carried.fit, PermissionModeFit.exact);
    });
  });
}
