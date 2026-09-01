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

  group('the store is located, and its transcripts are unreadable', () {
    test('it is the CLI data dir, not the IDE extensions dir', () {
      // `.antigravity` is the IDE's VS Code-style extensions directory. The CLI
      // writes `~/.gemini/antigravity-cli`, beside the IDE's `antigravity-ide`.
      expect(descriptor.store!.homeDirectoryName, '.gemini/antigravity-cli');
    });

    test('the format is the one that reads identity without content', () {
      // `AntigravityStoreReader` reads the id, the working directory, the name
      // and the step count out of this store; what it cannot read is message
      // *content*, because `steps.step_payload` is protobuf in an unpublished
      // schema. `none` described the first half and cost the second: with it,
      // `CliDetectionService` skipped the store outright and every Antigravity
      // conversation was invisible to the app.
      expect(descriptor.store!.format, AgentStoreFormat.antigravityStore);
    });

    test('locating the store does not conjure a chat view', () {
      expect(agentSupportsChatView(descriptor), isFalse);
      expect(defaultViewFor(descriptor), SessionView.terminal);
    });
  });

  group('what is still unverified stays unoffered', () {
    test('status comes from hooks, and only from hooks', () {
      // There is still no parseable state file and no watched TUI. What
      // changed is that the CLI turned out to have a hook system after all —
      // documented in a skill it ships rather than in `--help`, and proven by
      // a live `agy` 1.1.23 run whose callbacks reached a local server.
      expect(descriptor.statusStrategy, AgentStatusStrategy.hooks);
      expect(descriptor.grid.isEmpty, isTrue);
      expect(descriptor.stateFile, isNull);
      expect(descriptor.hooks, isNotNull);
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

  group('the conversation id is learnable after all', () {
    test('the CLI announces it, and the descriptor says how to read it', () {
      // The 2026-08-31 note recorded that `agy` announces its id nowhere, which
      // is why `interactiveResume` was declared with a flag nothing could ever
      // supply a value for. It prints its own resume command as it exits.
      final announcement = descriptor.launch.sessionIdAnnouncement;
      expect(announcement.isSupported, isTrue);
      expect(
        announcement.idIn(
          'Resume with -c (or command below):\n'
          'agy --conversation=df3c0708-a27f-4799-b761-57a657a84274\n',
        ),
        'df3c0708-a27f-4799-b761-57a657a84274',
      );
    });

    test('it still cannot be told an id we chose', () {
      // Unlike Claude Code's `--session-id`. Learning the id afterwards is the
      // whole reason the announcement exists.
      expect(descriptor.launch.sessionIdAssignment.isSupported, isFalse);
    });

    test('every claim carries where it was read', () {
      expect(descriptor.launch.sessionIdAnnouncement.evidence, isNotEmpty);
      expect(descriptor.launch.continueLatest.evidence, isNotEmpty);
    });
  });

  group('--continue is scoped, not a recency guess', () {
    test('the descriptor declares the flag and what it continues', () {
      final continueLatest = descriptor.launch.continueLatest;
      expect(continueLatest.isSupported, isTrue);
      expect(continueLatest.arguments, ['--continue']);
      // Not "the most recent conversation anywhere": `--continue` resolves
      // through `cache/last_conversations.json`, which is keyed by directory.
      expect(continueLatest.scope, AgentContinueScope.workingDirectory);
    });

    test('the agents nobody checked are left saying nothing', () {
      // The same rule as `fork` and `mcp`: unsupported means unverified, not
      // "this CLI has no such flag".
      for (final id in [AgentIds.claudeCode, AgentIds.codex]) {
        expect(
          registry.byId(id)!.launch.continueLatest.isSupported,
          isFalse,
          reason: id,
        );
      }
    });
  });

  group("concurrent resume is refused on the CLI's own warning", () {
    test('a second opener is not opted into', () {
      // `agy` warns rather than refusing — "Sending messages from both may
      // cause conflicts" — so this is false on evidence, not for want of a test.
      expect(descriptor.launch.allowsConcurrentResume, isFalse);
    });

    test('and that warning is not listed as a refusal marker', () {
      // `resumeConflict` is a post-mortem for a CLI that exited refusing.
      // Antigravity's line appears inside a session that goes on working.
      expect(descriptor.launch.resumeConflict.isEmpty, isTrue);
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
