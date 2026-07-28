import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/features/agents/data/agent_discovery_service.dart';
import 'package:chitragupta/src/features/agents/domain/agent_kind.dart';
import 'package:chitragupta/src/features/environments/domain/environment_kind.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

CommandResult _ok(String stdout) =>
    CommandResult(exitCode: 0, stdout: stdout, stderr: '');
const _notFound = CommandResult(exitCode: 1, stdout: '', stderr: 'not found');

void main() {
  group('pure helpers', () {
    test('agentExecutableName', () {
      expect(agentExecutableName(AgentKind.claudeCode), 'claude');
      expect(agentExecutableName(AgentKind.codex), 'codex');
      expect(agentExecutableName(AgentKind.antigravity), 'antigravity');
    });

    test('locateRequest uses where on Windows and a login shell in WSL', () {
      expect(
        locateRequest(EnvironmentKind.windowsNative, 'claude').executable,
        'where',
      );
      final wsl = locateRequest(EnvironmentKind.wsl, 'claude');
      expect(wsl.executable, 'bash');
      expect(wsl.arguments, ['-lc', 'command -v claude']);
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
                'antigravity' => _ok('C:\\bin\\antigravity.exe\r\n'),
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
        ).discover();

        expect(found.map((i) => i.agentKind), [
          AgentKind.claudeCode,
          AgentKind.antigravity,
        ]);
        final claude = found.first;
        expect(claude.executable.path, r'C:\bin\claude.exe');
        expect(claude.executable.environmentId, 'windows');
        expect(claude.version, '1.2.3');
        expect(found[1].version, isNull); // antigravity: located, no version
      },
    );

    test('returns nothing when the environment is unavailable', () async {
      final runner = FakeCommandRunner(
        throwError: CommandException('environment offline'),
      );
      final found = await AgentDiscoveryService(
        runner: runner,
        environment: wslEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
      ).discover();
      expect(found, isEmpty);
    });
  });
}
