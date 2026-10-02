import 'package:agent_cli/agent_cli.dart';
import 'package:test/test.dart';

import 'support/fake_command_runner.dart';
import 'support/fixtures.dart';

/// **The seams that broke this package's last edges back into an application.**
///
/// Each of the three collaborators an adapter used to hold — a
/// `CommandRunnerFactory`, an `ExecutionEnvironmentDao` and a Riverpod-backed
/// resolver — reached a database. They said one thing between them, "give me a
/// runner for this environment id", and that is now one function.
/// `CliStoreLocator` had the same shape: a factory
/// plus an installations DAO, for a `$HOME` and a Codex path.
///
/// These cases exist because a seam is only real if something drives it. Every
/// one of them composes the package with plain values and no host at all.
void main() {
  group('a RunnerResolver in place of the factory', () {
    test('resolves an environment id off a plain list', () {
      final windows = FakeCommandRunner(environmentId: 'windows');
      final resolve = runnerResolverFor([
        windowsEnv(),
        wslEnv(),
      ], factory: const CommandRunnerFactory());

      expect(resolve('windows').environmentId, 'windows');
      expect(resolve('wsl:Ubuntu'), isA<WslCommandRunner>());
      expect(() => resolve('nope'), throwsA(isA<StateError>()));
      expect(windows.requests, isEmpty);
    });

    test('the package places local and WSL, and refuses SSH in words', () {
      const factory = CommandRunnerFactory();

      expect(factory.forEnvironment(windowsEnv()), isA<LocalCommandRunner>());
      expect(factory.forEnvironment(wslEnv()), isA<WslCommandRunner>());
      expect(factory.canReachRemote, isFalse);
      expect(
        () => factory.forEnvironment(sshEnvFixture()),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('locally and in WSL only'),
          ),
        ),
      );
    });

    test('a host adds its own transport by overriding one method', () {
      // Which is what keeps Karmashala's SSH runner out of this package
      // without either copy re-deciding the local and WSL cases.
      final factory = _SshAwareFactory();

      expect(factory.canReachRemote, isTrue);
      expect(factory.forEnvironment(windowsEnv()), isA<LocalCommandRunner>());
      expect(factory.forEnvironment(sshEnvFixture()).environmentId, 'ssh:h1');
    });
  });

  group('an adapter takes the resolver and nothing else', () {
    ({FakeCommandRunner runner, RunnerResolver resolve}) fake() {
      final runner = FakeCommandRunner(environmentId: 'windows');
      return (runner: runner, resolve: (_) => runner);
    }

    test('Claude Code starts its process through the resolved runner', () {
      final f = fake();
      ClaudeCodeChatProtocol(runnerFor: f.resolve).start(
        AgentLaunch(
          workingDirectory: workingDirectory(),
          installation: agentInstallation(),
        ),
      );

      expect(f.runner.startRequests, hasLength(1));
      expect(
        f.runner.startRequests.single.executable,
        r'C:\Users\me\.bin\claude.exe',
      );
      expect(
        f.runner.startRequests.single.arguments,
        containsAllInOrder(['--output-format', 'stream-json']),
      );
    });

    test('every adapter resolves by the installation environment id', () {
      final asked = <String>[];
      CommandRunner resolve(String id) {
        asked.add(id);
        return FakeCommandRunner(environmentId: id);
      }

      final launch = AgentLaunch(
        workingDirectory: workingDirectory(environmentId: 'wsl:Ubuntu'),
        installation: agentInstallation(environmentId: 'wsl:Ubuntu'),
      );
      ClaudeCodeChatProtocol(runnerFor: resolve).start(launch);
      CodexChatProtocol(runnerFor: resolve).start(launch);
      AntigravityChatProtocol(runnerFor: resolve).start(launch);
      GenericChatProtocol(
        agentId: 'roverCli',
        runnerFor: resolve,
      ).start(launch);

      expect(asked, everyElement('wsl:Ubuntu'));
      expect(asked, hasLength(4));
    });
  });

  group('CliStoreLocator takes installations as values', () {
    test(r'the local store homes come from the registry and $HOME', () async {
      final locator = CliStoreLocator(
        runnerFor: (_) => FakeCommandRunner(),
        environment: {'USERPROFILE': r'C:\Users\me'},
      );

      final stores = await locator.locate([windowsEnv()]);

      expect(stores, hasLength(1));
      expect(
        stores.single.homeFor(AgentIds.claudeCode),
        r'C:\Users\me\.claude',
      );
      expect(stores.single.homeFor(AgentIds.codex), r'C:\Users\me\.codex');
      expect(
        stores.single.storeServerFor(AgentIds.codex),
        isNull,
        reason: 'no installations were passed, so no app-server to spawn',
      );
    });

    test('a Codex installation in the list becomes an app-server launch', () {
      // This used to be an `AgentInstallationDao.getByEnvironment`, which is a
      // database inside the one class that has to cross to a worker isolate.
      final locator = CliStoreLocator(
        runnerFor: (_) => FakeCommandRunner(),
        installations: [
          agentInstallation(id: 'a1', agentId: AgentIds.claudeCode),
          agentInstallation(
            id: 'a2',
            agentId: AgentIds.codex,
            path: r'C:\bin\codex.exe',
          ),
          agentInstallation(
            id: 'a3',
            agentId: AgentIds.codex,
            environmentId: 'wsl:Ubuntu',
            path: '/usr/bin/codex',
          ),
        ],
        environment: {'USERPROFILE': r'C:\Users\me'},
      );

      return locator.locate([windowsEnv()]).then((stores) {
        expect(stores.single.storeServerFor(AgentIds.codex), isNotNull);
        expect(
          stores.single.storeServerFor(AgentIds.codex)!.executable,
          r'C:\bin\codex.exe',
          reason: 'the WSL row belongs to the WSL store, not this one',
        );
      });
    });

    test("a WSL store is reached through the resolver's runner", () async {
      final wsl = FakeCommandRunner(
        environmentId: 'wsl:Ubuntu',
        responder: (_) =>
            const CommandResult(exitCode: 0, stdout: '/home/me', stderr: ''),
      );
      final locator = CliStoreLocator(
        runnerFor: (id) => id == 'wsl:Ubuntu' ? wsl : FakeCommandRunner(),
        environment: {'USERPROFILE': r'C:\Users\me'},
      );

      final stores = await locator.locate([windowsEnv(), wslEnv()]);

      expect(wsl.requests.single.arguments.last, r'printf %s "$HOME"');
      expect(
        stores.last.homeFor(AgentIds.claudeCode),
        r'\\wsl.localhost\Ubuntu\home\me\.claude',
      );
    });
  });

  group('the SQLite seam', () {
    test('no binding means "not recorded", never a zero', () async {
      // The package depends on no SQLite library, so a caller that supplies no
      // reader gets the answer a busy database gives.
      expect(
        await const AntigravityStoreReader().readStepCount('anything.db'),
        isNull,
      );
      expect(await const CodexLifetimeReader().read('anywhere'), isNull);
    });
  });

  group('ask, the one-shot mode', () {
    test(
      'closes stdin, because these CLIs wait on it forever otherwise',
      () async {
        final handle = FakeProcessHandle();
        final runner = FakeCommandRunner(processFactory: (_) => handle);
        final session = CliSession(
          installation: agentInstallation(),
          runner: runner,
        );

        final answers = session.ask('hi').toList();
        await Future<void>.delayed(Duration.zero);
        expect(handle.stdinClosed, isTrue);

        handle.emitStdout(
          '{"type":"assistant","message":{"content":'
          '[{"type":"text","text":"hello"}]}}',
        );
        handle.complete();
        expect(await answers, ['hello']);
        expect(session.isBusy, isFalse);
      },
    );

    test(
      'a non-zero exit with nothing said is reported, not swallowed',
      () async {
        final handle = FakeProcessHandle();
        final runner = FakeCommandRunner(processFactory: (_) => handle);
        final session = CliSession(
          installation: agentInstallation(),
          runner: runner,
        );

        final answers = session.ask('hi').toList();
        await Future<void>.delayed(Duration.zero);
        handle.emitStderr('not logged in');
        handle.complete(1);

        await expectLater(
          answers,
          throwsA(
            isA<CliSessionException>().having(
              (e) => e.toString(),
              'toString',
              allOf(contains('Claude Code'), contains('not logged in')),
            ),
          ),
        );
      },
    );
  });
}

/// What a host that *does* reach other machines adds — one method.
class _SshAwareFactory extends CommandRunnerFactory {
  @override
  bool get canReachRemote => true;

  @override
  CommandRunner unsupported(ExecutionEnvironment environment) =>
      FakeCommandRunner(environmentId: environment.id);
}
