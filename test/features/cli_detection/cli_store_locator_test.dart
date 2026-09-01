import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/features/agents/domain/agent_descriptor.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';

FakeCommandRunnerFactory _homeIs(String home) => FakeCommandRunnerFactory(
  fallback: FakeCommandRunner(
    responder: (_) => CommandResult(exitCode: 0, stdout: home, stderr: ''),
  ),
);

void main() {
  group('the local host store', () {
    // These cases exist because there were none. Every case in this file used
    // to name a WSL store, and the local one was only ever built when
    // `USERPROFILE` happened to be set — which it never is off Windows. So a
    // Mac located no store at all, and with no store there is nothing to read:
    // no detected projects, no sessions, no chat to adopt. The suite was
    // green throughout.

    test('a POSIX desktop reads \$HOME, with POSIX separators', () async {
      final stores = await CliStoreLocator(
        runnerFactory: _homeIs('/home/me'),
        environment: const {'HOME': '/Users/me'},
      ).locate([posixEnv()]);

      final local = stores.single;
      expect(local.environmentId, posixEnv().id);
      expect(local.claudeHome, '/Users/me/.claude');
      expect(local.codexHome, '/Users/me/.codex');
      expect(local.claudeHome, isNot(contains(r'\')));
    });

    test(
      'a Windows desktop reads %USERPROFILE%, with Windows separators',
      () async {
        final stores = await CliStoreLocator(
          runnerFactory: _homeIs('/home/me'),
          environment: const {'USERPROFILE': r'C:\Users\me'},
        ).locate([windowsEnv()]);

        final local = stores.single;
        expect(local.claudeHome, r'C:\Users\me\.claude');
        expect(local.codexHome, r'C:\Users\me\.codex');
      },
    );

    test('each host is asked only for the variable it actually sets', () async {
      // `USERPROFILE` on a Mac and `HOME` on Windows are both absent or
      // meaningless; neither is a fallback for the other, and reading the
      // wrong one would point the scan at a directory that is not the store.
      expect(
        await CliStoreLocator(
          runnerFactory: _homeIs('/home/me'),
          environment: const {'USERPROFILE': r'C:\Users\me'},
        ).locate([posixEnv()]),
        isEmpty,
      );
      expect(
        await CliStoreLocator(
          runnerFactory: _homeIs('/home/me'),
          environment: const {'HOME': '/Users/me'},
        ).locate([windowsEnv()]),
        isEmpty,
      );
    });

    test(
      'a blank home yields no store rather than a store at the root',
      () async {
        final stores = await CliStoreLocator(
          runnerFactory: _homeIs('/home/me'),
          environment: const {'HOME': '   '},
        ).locate([posixEnv()]);

        expect(stores, isEmpty);
      },
    );

    test('WSL is still located beside a Windows desktop', () async {
      final stores = await CliStoreLocator(
        runnerFactory: _homeIs('/home/me'),
        environment: const {'USERPROFILE': r'C:\Users\me'},
      ).locate([windowsEnv(), wslEnv()]);

      expect(stores.map((s) => s.environmentId), ['windows', 'wsl:Ubuntu']);
    });
  });

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
