import 'package:chitragupta/src/features/agents/data/antigravity_adapter.dart';
import 'package:chitragupta/src/features/agents/data/claude_code_adapter.dart';
import 'package:chitragupta/src/features/agents/data/codex_adapter.dart';
import 'package:chitragupta/src/features/agents/domain/agent_adapter.dart';
import 'package:chitragupta/src/features/agents/domain/agent_descriptor.dart';
import 'package:chitragupta/src/features/agents/domain/agent_kind.dart';
import 'package:chitragupta/src/features/agents/domain/agent_registry.dart';
import 'package:chitragupta/src/features/environments/domain/environment_kind.dart';
import 'package:chitragupta/src/features/settings/domain/permission_mode.dart';
import 'package:chitragupta/src/features/terminal/data/system_terminal_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

/// The observable launch behaviour of one built-in agent, written by hand.
///
/// Every field is a literal. Nothing here reads [AgentRegistry], so a descriptor
/// edit moves exactly one side of every assertion below and the test fails.
///
/// That independence is the whole point of this file. Loop 29 routed
/// `permissionArgsFor` through `AgentRegistry.builtIn`, which turned the old
/// "the launcher agrees with the registry" assertions into registry-vs-registry
/// comparisons that could not fail. The adapters' `*LaunchArgs` functions are
/// still genuinely separate code and are still asserted against — but they cover
/// only the headless path, and no independent source for the *terminal* path
/// survives. A golden is the only thing left that a descriptor edit cannot move.
class _AgentGolden {
  const _AgentGolden({
    required this.id,
    required this.displayName,
    required this.kind,
    required this.executable,
    required this.baseArguments,
    required this.permissionArguments,
    required this.permissionFits,
    required this.resumeArguments,
    required this.interactiveResumeArguments,
  });

  final String id;
  final String displayName;
  final AgentKind kind;

  /// The executable base name probed on both Windows and WSL.
  final String executable;

  /// Arguments every launch starts with, before permission flags.
  final List<String> baseArguments;

  /// The flags each [PermissionMode] adds.
  final Map<PermissionMode, List<String>> permissionArguments;

  /// How faithfully each mode maps onto this agent.
  ///
  /// Written out per mode, by hand, **because the arguments cannot tell you**:
  /// Claude Code's `ask` and Antigravity's `acceptEdits` are both empty lists
  /// and are opposites — one is the CLI's own default, the other is a mode we
  /// have no way to request. That is the distinction Loop 31 §4 asked for and
  /// the reason the descriptor declares fidelity instead of inferring it.
  final Map<PermissionMode, PermissionModeFit> permissionFits;

  /// What resuming session `sid` appends in the headless/protocol launch.
  final List<String> resumeArguments;

  /// What resuming session `sid` appends in an interactive terminal launch.
  final List<String> interactiveResumeArguments;

  /// The full headless argument vector for [mode], resuming `sid` when asked.
  List<String> launchArguments(PermissionMode mode, {required bool resume}) => [
    ...baseArguments,
    ...permissionArguments[mode]!,
    if (resume) ...resumeArguments,
  ];
}

/// The three agents Chitragupta ships, in registry order.
const List<_AgentGolden> _goldens = [
  _AgentGolden(
    id: 'claudeCode',
    displayName: 'Claude Code',
    kind: AgentKind.claudeCode,
    executable: 'claude',
    baseArguments: [
      '--input-format',
      'stream-json',
      '--output-format',
      'stream-json',
      '--verbose',
    ],
    permissionArguments: {
      PermissionMode.ask: ['--permission-mode', 'manual'],
      PermissionMode.acceptEdits: ['--permission-mode', 'acceptEdits'],
      PermissionMode.bypass: ['--permission-mode', 'bypassPermissions'],
    },
    // `ask` names `manual` rather than passing nothing: an unflagged session
    // starts in `auto` on a Pro/Max/Team account, so "no flag" was not the safe
    // mode it looked like.
    permissionFits: {
      PermissionMode.ask: PermissionModeFit.exact,
      PermissionMode.acceptEdits: PermissionModeFit.exact,
      PermissionMode.bypass: PermissionModeFit.exact,
    },
    resumeArguments: ['--resume', 'sid'],
    interactiveResumeArguments: ['--resume', 'sid'],
  ),
  _AgentGolden(
    id: 'codex',
    displayName: 'Codex CLI',
    kind: AgentKind.codex,
    executable: 'codex',
    baseArguments: ['app-server'],
    permissionArguments: {
      PermissionMode.ask: ['--ask-for-approval', 'on-request'],
      PermissionMode.acceptEdits: [
        '--sandbox',
        'workspace-write',
        '--ask-for-approval',
        'on-request',
      ],
      PermissionMode.bypass: ['--dangerously-bypass-approvals-and-sandbox'],
    },
    // Not accept-edits: the sandbox bounds writes to the working tree and the
    // approval policy still governs commands. Two values have been retired from
    // this slot by the real CLI — `on-failure` (0.145.0) and `untrusted`
    // (0.151.0) — see built_in_agents.dart for both transcripts.
    permissionFits: {
      PermissionMode.ask: PermissionModeFit.exact,
      PermissionMode.acceptEdits: PermissionModeFit.approximate,
      PermissionMode.bypass: PermissionModeFit.exact,
    },
    resumeArguments: ['--resume', 'sid'],
    // Interactively Codex resumes with a subcommand, not a flag.
    interactiveResumeArguments: ['resume', 'sid'],
  ),
  _AgentGolden(
    id: 'antigravity',
    displayName: 'Antigravity',
    kind: AgentKind.antigravity,
    // `agy`, not `antigravity` — the name the CLI installs itself under, and
    // the reason discovery never found it before.
    executable: 'agy',
    // Nothing headless is claimed: the stream-json protocol `agy --help`
    // documents has not been run, and the adapter parses plain text.
    baseArguments: [],
    permissionArguments: {
      // Prompting is the CLI's own unflagged behaviour, so `ask` is exact with
      // no arguments — the case `PermissionModeMapping.exact`'s `note` exists
      // for, and the opposite of the empty-because-unknown mappings this entry
      // used to carry.
      PermissionMode.ask: [],
      PermissionMode.acceptEdits: ['--mode', 'accept-edits'],
      PermissionMode.bypass: ['--dangerously-skip-permissions'],
    },
    // All three now map exactly, read off `agy --help` (1.1.22). The previous
    // `--yolo` was not a flag this CLI has.
    permissionFits: {
      PermissionMode.ask: PermissionModeFit.exact,
      PermissionMode.acceptEdits: PermissionModeFit.exact,
      PermissionMode.bypass: PermissionModeFit.exact,
    },
    // `--conversation  Resume a previous conversation by ID`. One convention
    // for both launches — there is no subcommand form as there is for Codex.
    resumeArguments: ['--conversation', 'sid'],
    interactiveResumeArguments: ['--conversation', 'sid'],
  ),
];

void main() {
  const registry = AgentRegistry.builtIn;

  test('ships exactly the golden agents, in order', () {
    expect(registry.descriptors.map((d) => d.id), _goldens.map((g) => g.id));
    expect(
      registry.descriptors.map((d) => d.displayName),
      _goldens.map((g) => g.displayName),
    );
    expect(
      registry.descriptors.map((d) => d.kind),
      _goldens.map((g) => g.kind),
    );
    // Every agent with a protocol adapter is shipped: the enum has no orphans.
    expect(_goldens.map((g) => g.kind), AgentKind.values);
    // Rows written before the id migration hold `AgentKind.name`, so the id and
    // the kind must still agree for the three built-ins to load.
    for (final golden in _goldens) {
      expect(golden.id, golden.kind.name);
    }
    expect(registry.byId('nope'), isNull);
  });

  test('probes the golden executable name on both platforms', () {
    for (final golden in _goldens) {
      final binaries = registry.byId(golden.id)!.binaries;
      expect(binaries.forKind(EnvironmentKind.windowsNative), [
        golden.executable,
      ], reason: golden.id);
      expect(binaries.forKind(EnvironmentKind.wsl), [
        golden.executable,
      ], reason: golden.id);
    }
  });

  test('the terminal launcher passes the golden permission flags', () {
    for (final golden in _goldens) {
      final spec = registry.byId(golden.id)!.launch;
      for (final mode in PermissionMode.values) {
        final expected = golden.permissionArguments[mode]!;
        // What an external terminal launch actually passes...
        expect(
          permissionArgsFor(golden.id, mode),
          expected,
          reason: 'launcher: ${golden.id} / ${mode.name}',
        );
        // ...and what the descriptor declares, which must be the same thing.
        expect(
          spec.permissionArgumentsFor(mode),
          expected,
          reason: 'descriptor: ${golden.id} / ${mode.name}',
        );
      }
    }
  });

  test('the registry declares the golden permission fidelity', () {
    for (final golden in _goldens) {
      final spec = registry.byId(golden.id)!.launch;
      for (final mode in PermissionMode.values) {
        expect(
          spec.permissionFitFor(mode),
          golden.permissionFits[mode],
          reason: '${golden.id} / ${mode.name}',
        );
      }
    }
  });

  test('a mode that does not map is absent, not empty', () {
    // The two halves of the same fact, checked against each other: what the
    // control offers must be exactly what the descriptor can express, and a
    // `none` mode must contribute no arguments. Antigravity is the agent that
    // makes this test able to fail — restoring its old `ask: []` entry would
    // make it expressible again while its arguments stayed empty.
    for (final golden in _goldens) {
      final spec = registry.byId(golden.id)!.launch;
      final expressible = [
        for (final mode in PermissionMode.values)
          if (golden.permissionFits[mode] != PermissionModeFit.none) mode,
      ];
      expect(spec.expressiblePermissionModes, expressible, reason: golden.id);
      for (final mode in PermissionMode.values) {
        if (golden.permissionFits[mode] != PermissionModeFit.none) continue;
        expect(
          spec.permissionArgumentsFor(mode),
          isEmpty,
          reason: '${golden.id} / ${mode.name} maps to nothing',
        );
        expect(spec.permissionNoteFor(mode), isNull);
      }
    }
  });

  test('every approximate mapping explains itself', () {
    // An approximation the user cannot see the shape of is worse than none:
    // they read the mode's own label and believe it. The constructor requires a
    // note; this pins that the shipped data actually carries one worth reading.
    for (final golden in _goldens) {
      final spec = registry.byId(golden.id)!.launch;
      for (final mode in PermissionMode.values) {
        if (spec.permissionFitFor(mode) != PermissionModeFit.approximate) {
          continue;
        }
        expect(
          spec.permissionNoteFor(mode),
          isNotNull,
          reason: '${golden.id} / ${mode.name}',
        );
        expect(spec.permissionNoteFor(mode)!.length, greaterThan(20));
      }
    }
  });

  test('interactive resume uses the golden convention', () {
    for (final golden in _goldens) {
      expect(
        registry.byId(golden.id)!.launch.interactiveResume.argumentsFor('sid'),
        golden.interactiveResumeArguments,
        reason: golden.id,
      );
    }
  });

  test('the adapters and the registry both build the golden launch', () {
    AgentLaunch launch(PermissionMode permission, String? resume) =>
        AgentLaunch(
          workingDirectory: repository().path,
          installation: agentInstallation(),
          permissionMode: permission,
          resumeSessionId: resume,
        );

    List<String> fromRegistry(String id, PermissionMode mode, String? resume) {
      final spec = registry.byId(id)!.launch;
      return [
        ...spec.baseArguments,
        ...spec.permissionArgumentsFor(mode),
        if (resume != null) ...spec.resume.argumentsFor(resume),
      ];
    }

    final adapters = <String, List<String> Function(AgentLaunch)>{
      'claudeCode': claudeLaunchArgs,
      'codex': codexLaunchArgs,
      'antigravity': antigravityLaunchArgs,
    };

    for (final golden in _goldens) {
      for (final mode in PermissionMode.values) {
        for (final resume in [null, 'sid']) {
          final expected = golden.launchArguments(mode, resume: resume != null);
          final reason = '${golden.id} / ${mode.name} / $resume';
          // The hand-written adapter function...
          expect(
            adapters[golden.id]!(launch(mode, resume)),
            expected,
            reason: 'adapter: $reason',
          );
          // ...and the descriptor, composed the way GenericAgentAdapter does.
          expect(
            fromRegistry(golden.id, mode, resume),
            expected,
            reason: 'registry: $reason',
          );
        }
      }
    }
  });

  test(
    'store specs describe only the agents with an on-disk session store',
    () {
      expect(registry.byId('claudeCode')!.store!.homeDirectoryName, '.claude');
      expect(
        registry.byId('claudeCode')!.store!.format,
        AgentStoreFormat.claudeJsonl,
      );
      expect(registry.byId('codex')!.store!.homeDirectoryName, '.codex');
      expect(
        registry.byId('codex')!.store!.format,
        AgentStoreFormat.codexRollout,
      );
      // Antigravity's store is located but deliberately not readable: the
      // conversations are encrypted, so the descriptor records where they are
      // *and* that nothing here can parse them.
      expect(
        registry.byId('antigravity')!.store!.homeDirectoryName,
        '.gemini/antigravity-cli',
      );
      expect(
        registry.byId('antigravity')!.store!.format,
        AgentStoreFormat.none,
      );
    },
  );

  test('status strategies reflect what each agent actually supports', () {
    expect(
      registry.byId('claudeCode')!.statusStrategy,
      AgentStatusStrategy.hooks,
    );
    expect(
      registry.byId('codex')!.statusStrategy,
      AgentStatusStrategy.stateFile,
    );
    // Antigravity's hooks are documented only in a skill the CLI ships, never
    // in `--help`, which is why this said `none` until a live run fired them.
    expect(
      registry.byId('antigravity')!.statusStrategy,
      AgentStatusStrategy.hooks,
    );
  });
}
