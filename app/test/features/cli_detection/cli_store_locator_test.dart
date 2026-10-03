import 'package:agent_cli/process.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';
import 'package:agent_cli/read.dart';

RunnerResolver _homeIs(String home) {
  final runner = FakeCommandRunner(
    responder: (_) => CommandResult(exitCode: 0, stdout: home, stderr: ''),
  );
  return (_) => runner;
}

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
        runnerFor: _homeIs('/home/me'),
        environment: const {'HOME': '/Users/me'},
      ).locate([posixEnv()]);

      final local = stores.single;
      expect(local.environmentId, posixEnv().id);
      expect(local.homeFor(AgentIds.claudeCode), '/Users/me/.claude');
      expect(local.homeFor(AgentIds.codex), '/Users/me/.codex');
      expect(local.homeFor(AgentIds.claudeCode), isNot(contains(r'\')));
    });

    test(
      'a Windows desktop reads %USERPROFILE%, with Windows separators',
      () async {
        final stores = await CliStoreLocator(
          runnerFor: _homeIs('/home/me'),
          environment: const {'USERPROFILE': r'C:\Users\me'},
        ).locate([windowsEnv()]);

        final local = stores.single;
        expect(local.homeFor(AgentIds.claudeCode), r'C:\Users\me\.claude');
        expect(local.homeFor(AgentIds.codex), r'C:\Users\me\.codex');
      },
    );

    test('each host is asked only for the variable it actually sets', () async {
      // `USERPROFILE` on a Mac and `HOME` on Windows are both absent or
      // meaningless; neither is a fallback for the other, and reading the
      // wrong one would point the scan at a directory that is not the store.
      expect(
        await CliStoreLocator(
          runnerFor: _homeIs('/home/me'),
          environment: const {'USERPROFILE': r'C:\Users\me'},
        ).locate([posixEnv()]),
        isEmpty,
      );
      expect(
        await CliStoreLocator(
          runnerFor: _homeIs('/home/me'),
          environment: const {'HOME': '/Users/me'},
        ).locate([windowsEnv()]),
        isEmpty,
      );
    });

    test(
      'a blank home yields no store rather than a store at the root',
      () async {
        final stores = await CliStoreLocator(
          runnerFor: _homeIs('/home/me'),
          environment: const {'HOME': '   '},
        ).locate([posixEnv()]);

        expect(stores, isEmpty);
      },
    );

    test('WSL is still located beside a Windows desktop', () async {
      final stores = await CliStoreLocator(
        runnerFor: _homeIs('/home/me'),
        environment: const {'USERPROFILE': r'C:\Users\me'},
      ).locate([windowsEnv(), wslEnv()]);

      expect(stores.map((s) => s.environmentId), ['windows', 'wsl:Ubuntu']);
    });
  });

  test('builds one home per descriptor that declares a store', () async {
    final stores = await CliStoreLocator(
      runnerFor: _homeIs('/home/me'),
    ).locate([windowsEnv(), wslEnv()]);

    final wsl = stores.firstWhere((s) => s.environmentId == 'wsl:Ubuntu');
    // The ACP agents whose CLIs keep a home declare it too; Grok declares none.
    expect(wsl.homesByAgentId.keys, [
      'claudeCode',
      'codex',
      'antigravity',
      'claude-acp',
      'codex-acp',
      'antigravity-acp',
    ]);
    expect(
      wsl.homeFor(AgentIds.claudeCode),
      r'\\wsl.localhost\Ubuntu\home\me\.claude',
    );
    expect(
      wsl.homeFor(AgentIds.codex),
      r'\\wsl.localhost\Ubuntu\home\me\.codex',
    );
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
      runnerFor: _homeIs('/home/me'),
      registry: const AgentRegistry([DataOnlyAgentAdapter(storeless)]),
    ).locate([windowsEnv(), wslEnv()]);

    expect(stores, isNotEmpty);
    expect(stores.every((s) => s.homesByAgentId.isEmpty), isTrue);
    expect(stores.every((s) => s.homeFor(AgentIds.claudeCode) == null), isTrue);
  });

  test(
    'a new descriptor with a store gets a home without code changes',
    () async {
      const newAgent = AgentDescriptor(
        id: 'cursorAgent',
        displayName: 'Cursor Agent',
        binaries: AgentBinaries(windows: ['cursor'], posix: ['cursor']),
        store: AgentStoreSpec(homeDirectoryName: '.cursor'),
      );

      final stores = await CliStoreLocator(
        runnerFor: _homeIs('/home/me'),
        registry: const AgentRegistry([DataOnlyAgentAdapter(newAgent)]),
      ).locate([windowsEnv(), wslEnv()]);

      final wsl = stores.firstWhere((s) => s.environmentId == 'wsl:Ubuntu');
      expect(
        wsl.homesByAgentId['cursorAgent'],
        r'\\wsl.localhost\Ubuntu\home\me\.cursor',
      );
    },
  );

  test('an unreachable WSL home contributes no store', () async {
    final offline = FakeCommandRunner(throwError: CommandException('offline'));

    final stores = await CliStoreLocator(
      runnerFor: (_) => offline,
    ).locate([windowsEnv(), wslEnv()]);

    expect(stores.where((s) => s.environmentId == 'wsl:Ubuntu'), isEmpty);
  });
}
