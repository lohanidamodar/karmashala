import 'package:agent_cli/src/process/command_runner.dart';
import 'package:agent_cli/src/agents/data/agent_discovery_service.dart';
import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/environments/environment_kind.dart';
import 'package:test/test.dart';

import '../support/fake_command_runner.dart';
import '../support/fakes.dart';
import '../support/fixtures.dart';

CommandResult _ok(String stdout) =>
    CommandResult(exitCode: 0, stdout: stdout, stderr: '');
const _notFound = CommandResult(exitCode: 1, stdout: '', stderr: 'not found');

void main() {
  group('pure helpers', () {
    test('locateRequest uses where on Windows and a login shell in WSL', () {
      expect(
        locateRequest(EnvironmentKind.windowsNative, 'claude').executable,
        'where',
      );
      final wsl = locateRequest(EnvironmentKind.wsl, 'claude');
      expect(wsl.executable, 'bash');
      expect(wsl.arguments, ['-lc', 'command -v claude']);
    });

    test('the interactive lookup marks its answer and ignores its exit', () {
      final req = interactiveLocateRequest('claude', loginShell: '/bin/zsh');
      expect(req.executable, '/bin/zsh');
      expect(req.arguments.first, '-ilc');
      expect(req.arguments.last, contains(kAgentPathMarker));
      expect(req.arguments.last, contains('command -v claude'));
    });

    test('markedPath reads past whatever the startup files printed', () {
      expect(
        markedPath(
          'Powerlevel10k: loading\n'
          'nvm: using v22\n'
          '$kAgentPathMarker/Users/me/.local/bin/claude \n',
        ),
        '/Users/me/.local/bin/claude',
      );
      // A shell that printed plenty and located nothing has not located
      // something: an unmarked first line is not an answer.
      expect(markedPath('/usr/bin/env: banner\nno match\n'), isNull);
      expect(markedPath('$kAgentPathMarker\n'), isNull);
    });

    test('firstNonEmptyLine', () {
      expect(
        firstNonEmptyLine('\r\n  C:\\bin\\claude.exe \r\nx'),
        r'C:\bin\claude.exe',
      );
      expect(firstNonEmptyLine('   \n  '), isNull);
    });

    test('parseAgentVersion extracts semver, else first line, else null', () {
      expect(parseAgentVersion('claude 1.2.3 (build 9)'), '1.2.3');
      expect(parseAgentVersion('1.4.0-beta.1\n'), '1.4.0-beta.1');
      expect(parseAgentVersion('nightly\n'), 'nightly');
      expect(parseAgentVersion('   '), isNull);
    });
  });

  group('AgentDiscoveryService', () {
    test(
      'discovers located agents with versions; skips missing ones',
      () async {
        final runner = FakeCommandRunner(
          responder: (req) {
            if (req.executable == 'where') {
              return switch (req.arguments.first) {
                'claude' => _ok('C:\\bin\\claude.exe\r\n'),
                // The CLI installs itself as `agy`; nothing is on PATH
                // under the name the registry used to probe for.
                'agy' => _ok('C:\\bin\\agy.exe\r\n'),
                _ => _notFound, // codex not installed
              };
            }
            if (req.arguments.contains('--version')) {
              if (req.executable.contains('claude')) {
                return _ok('1.2.3 (Claude Code)');
              }
              return _notFound; // antigravity --version fails
            }
            return _ok('');
          },
        );

        final found = await AgentDiscoveryService(
          runner: runner,
          environment: windowsEnv(),
          ids: SequentialIdGenerator(),
          clock: FixedClock(testTime),
          // This test is about the PATH lookup; with no variables set, no
          // descriptor's declared install path expands into a probe.
          hostEnvironment: const {},
        ).discover();

        expect(found.map((i) => i.agentId), [
          AgentIds.claudeCode,
          AgentIds.antigravity,
        ]);
        final claude = found.first;
        expect(claude.executable.path, r'C:\bin\claude.exe');
        expect(claude.executable.environmentId, 'windows');
        expect(claude.version, '1.2.3');
        expect(found[1].version, isNull); // antigravity: located, no version
      },
    );

    test('every probe discovery runs carries a bound', () async {
      final runner = FakeCommandRunner(
        responder: (req) => req.executable == 'where'
            ? _ok('C:\\bin\\${req.arguments.first}.exe\r\n')
            : _ok('1.0.0'),
      );
      await AgentDiscoveryService(
        runner: runner,
        environment: windowsEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
        hostEnvironment: const {},
      ).discover();

      expect(runner.requests, isNotEmpty);
      expect(runner.requests.map((r) => r.timeout).toSet(), {
        kProbeTimeout,
      }, reason: 'a wedged where or --version must not hang discovery forever');
    });

    test('returns nothing when the environment is unavailable', () async {
      final runner = FakeCommandRunner(
        throwError: CommandException('environment offline'),
      );
      final found = await AgentDiscoveryService(
        runner: runner,
        environment: wslEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
        hostEnvironment: const {},
      ).discover();
      expect(found, isEmpty);
    });
  });

  group('the local host is asked the way a terminal would ask', () {
    // What a login shell answers on a Mac whose PATH is set in `~/.zshrc`:
    // nothing, because `-l` never reads that file. Launched from a terminal
    // the app never sees this — the shell it spawns inherits the terminal's
    // PATH — so it only ever bit users who launched the installed app.
    FakeCommandRunner shellRunner({required bool interactiveFinds}) =>
        FakeCommandRunner(
          responder: (req) {
            final script = req.arguments.length > 1 ? req.arguments.last : '';
            if (req.arguments.firstOrNull == '-ilc') {
              return interactiveFinds && script.contains('command -v claude')
                  ? _ok('$kAgentPathMarker/Users/me/.local/bin/claude\n')
                  : _ok('a plugin said something\n');
            }
            if (req.arguments.firstOrNull == '-lc') return _notFound;
            return _ok('2.1.259 (Claude Code)');
          },
        );

    test(
      'a second time, interactively, when the login shell finds none',
      () async {
        final runner = shellRunner(interactiveFinds: true);
        final found = await AgentDiscoveryService(
          runner: runner,
          environment: posixEnv(),
          ids: SequentialIdGenerator(),
          clock: FixedClock(testTime),
          hostEnvironment: const {},
        ).discover();

        final claude = found.singleWhere(
          (i) => i.agentId == AgentIds.claudeCode,
        );
        expect(claude.executable.path, '/Users/me/.local/bin/claude');
        expect(claude.version, '2.1.259');
      },
    );

    test('and still reports nothing when neither shell has it', () async {
      final found = await AgentDiscoveryService(
        runner: shellRunner(interactiveFinds: false),
        environment: posixEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
        hostEnvironment: const {},
      ).discover();
      expect(found, isEmpty);
    });

    test('a remote environment is not asked twice', () async {
      // WSL and SSH are configured through their profile files, and starting an
      // interactive shell down a remote connection is a different kind of
      // expensive.
      final runner = shellRunner(interactiveFinds: true);
      final found = await AgentDiscoveryService(
        runner: runner,
        environment: wslEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
        hostEnvironment: const {},
      ).discover();

      expect(found, isEmpty);
      expect(
        runner.requests.where((r) => r.arguments.contains('-ilc')),
        isEmpty,
      );
    });
  });
}
