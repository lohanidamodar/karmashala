import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/features/agents/domain/agent_descriptor.dart';
import 'package:chitragupta/src/features/agents/domain/agent_registry.dart';
import 'package:chitragupta/src/features/cli_detection/application/cli_detection_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';

FakeCommandRunnerFactory _homeIs(String home) => FakeCommandRunnerFactory(
  fallback: FakeCommandRunner(
    responder: (_) => CommandResult(exitCode: 0, stdout: home, stderr: ''),
  ),
);

void main() {
  test('builds one home per descriptor that declares a store', () async {
    final stores = await CliStoreLocator(
      runnerFactory: _homeIs('/home/me'),
    ).locate([windowsEnv(), wslEnv()]);

    final wsl = stores.firstWhere((s) => s.environmentId == 'wsl:Ubuntu');
    expect(wsl.homesByAgentId.keys, ['claudeCode', 'codex', 'antigravity']);
    expect(wsl.claudeHome, r'\\wsl.localhost\Ubuntu\home\me\.claude');
    expect(wsl.codexHome, r'\\wsl.localhost\Ubuntu\home\me\.codex');
    // A home is located for an agent whose store we cannot *read*, which is the
    // point of keeping location and format separate. The nested directory is
    // also the first one in the registry, so this is where that is exercised.
    expect(
      wsl.homesByAgentId['antigravity'],
      r'\\wsl.localhost\Ubuntu\home\me\.gemini/antigravity-cli',
    );
  });

  test('a registry whose agents have no store yields empty homes', () async {
    // A descriptor written for this rule. It used to be Antigravity, which now
    // declares a store, and the rule under test is about a descriptor with no
    // store at all rather than about any shipped agent.
    const storeless = AgentDescriptor(
      id: 'storeless',
      displayName: 'Storeless Agent',
      binaries: AgentBinaries(windows: ['s'], posix: ['s']),
    );

    final stores = await CliStoreLocator(
      runnerFactory: _homeIs('/home/me'),
      registry: const AgentRegistry([storeless]),
    ).locate([windowsEnv(), wslEnv()]);

    expect(stores, isNotEmpty);
    expect(stores.every((s) => s.homesByAgentId.isEmpty), isTrue);
    expect(stores.every((s) => s.claudeHome == null), isTrue);
  });

  test(
    'a new descriptor with a store gets a home without code changes',
    () async {
      const newAgent = AgentDescriptor(
        id: 'cursorAgent',
        displayName: 'Cursor Agent',
        binaries: AgentBinaries(windows: ['cursor'], posix: ['cursor']),
        store: AgentStoreSpec(
          homeDirectoryName: '.cursor',
          format: AgentStoreFormat.none,
        ),
      );

      final stores = await CliStoreLocator(
        runnerFactory: _homeIs('/home/me'),
        registry: const AgentRegistry([newAgent]),
      ).locate([windowsEnv(), wslEnv()]);

      final wsl = stores.firstWhere((s) => s.environmentId == 'wsl:Ubuntu');
      expect(
        wsl.homesByAgentId['cursorAgent'],
        r'\\wsl.localhost\Ubuntu\home\me\.cursor',
      );
    },
  );

  test('an unreachable WSL home contributes no store', () async {
    final factory = FakeCommandRunnerFactory(
      fallback: FakeCommandRunner(throwError: CommandException('offline')),
    );

    final stores = await CliStoreLocator(
      runnerFactory: factory,
    ).locate([windowsEnv(), wslEnv()]);

    expect(stores.where((s) => s.environmentId == 'wsl:Ubuntu'), isEmpty);
  });
}
