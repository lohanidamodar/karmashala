import 'package:chitragupta/src/features/agents/data/agent_discovery_service.dart';
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

void main() {
  const registry = AgentRegistry.builtIn;

  test('ships the three agents in AgentKind order', () {
    expect(registry.descriptors.map((d) => d.id), [
      'claudeCode',
      'codex',
      'antigravity',
    ]);
    expect(registry.descriptors.map((d) => d.kind), AgentKind.values);
    expect(registry.descriptors.map((d) => d.displayName), [
      'Claude Code',
      'Codex CLI',
      'Antigravity',
    ]);
  });

  test('id round-trips through AgentKind', () {
    for (final kind in AgentKind.values) {
      final descriptor = registry.forKind(kind)!;
      expect(descriptor.id, kind.name);
      expect(registry.byId(kind.name), same(descriptor));
    }
    expect(registry.byId('nope'), isNull);
  });

  test('binary names match agentExecutableName on both platforms', () {
    for (final kind in AgentKind.values) {
      final binaries = registry.forKind(kind)!.binaries;
      expect(
        binaries.forKind(EnvironmentKind.windowsNative).first,
        agentExecutableName(kind),
      );
      expect(
        binaries.forKind(EnvironmentKind.wsl).first,
        agentExecutableName(kind),
      );
    }
  });

  test('permission arguments match the terminal launcher for every mode', () {
    for (final kind in AgentKind.values) {
      final spec = registry.forKind(kind)!.launch;
      for (final mode in PermissionMode.values) {
        expect(
          spec.permissionArgumentsFor(mode),
          permissionArgsFor(kind.name, mode),
          reason: '${kind.name} / ${mode.name}',
        );
      }
    }
  });

  test('interactive resume matches the terminal resume convention', () {
    expect(
      registry.byId('claudeCode')!.launch.interactiveResume.argumentsFor('sid'),
      ['--resume', 'sid'],
    );
    expect(
      registry.byId('codex')!.launch.interactiveResume.argumentsFor('sid'),
      ['resume', 'sid'],
    );
    expect(
      registry
          .byId('antigravity')!
          .launch
          .interactiveResume
          .argumentsFor('sid'),
      isEmpty,
    );
  });

  test('headless launch data reproduces what the adapters build', () {
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

    for (final mode in PermissionMode.values) {
      for (final resume in [null, 'sid']) {
        expect(
          fromRegistry('claudeCode', mode, resume),
          claudeLaunchArgs(launch(mode, resume)),
          reason: 'claudeCode / ${mode.name} / $resume',
        );
        expect(
          fromRegistry('codex', mode, resume),
          codexLaunchArgs(launch(mode, resume)),
          reason: 'codex / ${mode.name} / $resume',
        );
        expect(
          fromRegistry('antigravity', mode, resume),
          antigravityLaunchArgs(launch(mode, resume)),
          reason: 'antigravity / ${mode.name} / $resume',
        );
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
