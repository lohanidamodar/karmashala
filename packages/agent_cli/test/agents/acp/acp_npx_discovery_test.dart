import 'package:agent_cli/src/agents/data/agent_discovery_service.dart';
import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/agents/domain/agent_installation.dart';
import 'package:agent_cli/src/environments/environment_path.dart';
import 'package:agent_cli/src/process/command_runner.dart';
import 'package:test/test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

CommandResult _ok(String stdout) =>
    CommandResult(exitCode: 0, stdout: stdout, stderr: '');
const _notFound = CommandResult(exitCode: 1, stdout: '', stderr: '');

/// An ACP agent whose binary is absent is still an installation when `npx`
/// can run its package.
void main() {
  group('npx fallback', () {
    test('records npx with the package as leading arguments', () async {
      final runner = FakeCommandRunner(
        responder: (req) {
          if (req.executable == 'where') {
            return req.arguments.single == 'npx.cmd'
                ? _ok('C:\\Program Files\\nodejs\\npx.cmd\r\n')
                : _notFound;
          }
          return _notFound;
        },
      );
      final found = await AgentDiscoveryService(
        runner: runner,
        environment: windowsEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
        hostEnvironment: const {},
      ).discover();

      // Every ACP agent names a package; no terminal agent is found.
      expect(found.map((i) => i.agentId), [
        AgentIds.claudeAcp,
        AgentIds.codexAcp,
        AgentIds.geminiCli,
        AgentIds.grok,
      ]);
      final claude = found.first;
      expect(claude.executable.path, r'C:\Program Files\nodejs\npx.cmd');
      expect(claude.leadingArguments, [
        '-y',
        '@agentclientprotocol/claude-agent-acp',
      ]);
      // No binary was run, so there is no version and no reading time.
      expect(claude.version, isNull);
      expect(claude.versionReadAt, isNull);
      expect(found[2].leadingArguments, ['-y', '@google/gemini-cli']);

      // One `npx` lookup serves the whole sweep.
      expect(
        runner.requests.where((r) => r.arguments.single == 'npx.cmd'),
        hasLength(1),
      );
      // Windows asks for `npx.cmd`, never the shell script `where npx` lists
      // first.
      expect(
        runner.requests.where((r) => r.arguments.single == 'npx'),
        isEmpty,
      );
    });

    test('a POSIX environment asks for npx through the login shell', () async {
      final runner = FakeCommandRunner(
        responder: (req) {
          final script = req.arguments.length > 1 ? req.arguments.last : '';
          if (script == 'command -v npx') return _ok('/usr/bin/npx\n');
          return _notFound;
        },
      );
      final found = await AgentDiscoveryService(
        runner: runner,
        environment: wslEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
        hostEnvironment: const {},
      ).discover();
      expect(found, hasLength(4));
      expect(found.first.executable.path, '/usr/bin/npx');
      expect(found.first.executable.environmentId, 'wsl:Ubuntu');
    });

    test('an installed binary wins over npx', () async {
      final runner = FakeCommandRunner(
        responder: (req) {
          if (req.executable == 'where') {
            return switch (req.arguments.single) {
              'gemini' => _ok('C:\\bin\\gemini.cmd\r\n'),
              'npx.cmd' => _ok('C:\\nodejs\\npx.cmd\r\n'),
              _ => _notFound,
            };
          }
          if (req.arguments.contains('--version')) return _ok('0.62.0');
          return _notFound;
        },
      );
      final found = await AgentDiscoveryService(
        runner: runner,
        environment: windowsEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
        hostEnvironment: const {},
      ).discover();
      final gemini = found.singleWhere((i) => i.agentId == AgentIds.geminiCli);
      expect(gemini.executable.path, r'C:\bin\gemini.cmd');
      expect(gemini.leadingArguments, isEmpty);
      expect(gemini.version, '0.62.0');
    });

    test('without npx an ACP agent is simply missing', () async {
      final runner = FakeCommandRunner(responder: (_) => _notFound);
      final probe = await AgentDiscoveryService(
        runner: runner,
        environment: windowsEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
        hostEnvironment: const {},
      ).probeEnvironment();
      expect(probe.found, isEmpty);
      expect(probe.missingAgentIds, AgentIds.builtIn);
    });

    test('the lookup is not repeated for a terminal agent', () async {
      final runner = FakeCommandRunner(responder: (_) => _notFound);
      await AgentDiscoveryService(
        runner: runner,
        environment: windowsEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
        hostEnvironment: const {},
      ).discover(agentIds: {AgentIds.claudeCode, AgentIds.codex});
      expect(
        runner.requests.where((r) => r.arguments.contains('npx.cmd')),
        isEmpty,
      );
    });
  });

  group('AgentInstallation.leadingArguments', () {
    test('defaults to none and takes part in equality and copyWith', () {
      final plain = agentInstallation();
      expect(plain.leadingArguments, isEmpty);
      final viaNpx = plain.copyWith(leadingArguments: ['-y', 'pkg']);
      expect(viaNpx.leadingArguments, ['-y', 'pkg']);
      expect(viaNpx, isNot(equals(plain)));
      expect(
        viaNpx,
        AgentInstallation(
          id: plain.id,
          agentId: plain.agentId,
          executable: EnvironmentPath(
            environmentId: plain.environmentId,
            path: plain.executable.path,
          ),
          version: plain.version,
          createdAt: plain.createdAt,
          leadingArguments: const ['-y', 'pkg'],
        ),
      );
      expect(viaNpx.hashCode, isNot(plain.hashCode));
    });
  });
}
