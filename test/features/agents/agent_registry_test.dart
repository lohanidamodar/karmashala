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
      PermissionMode.ask: [],
      PermissionMode.acceptEdits: ['--permission-mode', 'acceptEdits'],
      PermissionMode.bypass: ['--permission-mode', 'bypassPermissions'],
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
      PermissionMode.acceptEdits: ['--ask-for-approval', 'on-failure'],
      PermissionMode.bypass: ['--dangerously-bypass-approvals-and-sandbox'],
    },
    resumeArguments: ['--resume', 'sid'],
    // Interactively Codex resumes with a subcommand, not a flag.
    interactiveResumeArguments: ['resume', 'sid'],
  ),
  _AgentGolden(
    id: 'antigravity',
    displayName: 'Antigravity',
    kind: AgentKind.antigravity,
    executable: 'antigravity',
    baseArguments: ['--stdio'],
    permissionArguments: {
      PermissionMode.ask: [],
      PermissionMode.acceptEdits: [],
      PermissionMode.bypass: ['--yolo'],
    },
    resumeArguments: ['--resume', 'sid'],
    // No documented interactive resume convention.
    interactiveResumeArguments: [],
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
      expect(registry.byId('antigravity')!.store, isNull);
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
    expect(
      registry.byId('antigravity')!.statusStrategy,
      AgentStatusStrategy.none,
    );
  });
}
