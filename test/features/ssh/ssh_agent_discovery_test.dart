import 'package:agent_cli/process.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// Agent discovery over SSH is the same code path as WSL discovery. These tests
/// pin that claim: no SSH-specific discovery logic exists, only a registry that
/// knows a remote host is POSIX-shaped.
void main() {
  final remote = ExecutionEnvironment(
    id: sshEnvironmentId('h1'),
    kind: EnvironmentKind.ssh,
    name: 'build-box',
    sshHostId: 'h1',
    createdAt: testTime,
  );

  test('a remote host is probed with a POSIX login shell, like WSL', () {
    final ssh = locateRequest(EnvironmentKind.ssh, 'claude');
    expect(ssh.executable, 'bash');
    expect(ssh.arguments, ['-lc', 'command -v claude']);
    expect(
      ssh.executable,
      locateRequest(EnvironmentKind.wsl, 'claude').executable,
    );
  });

  test('a remote host probes the POSIX binary names, not the Windows ones', () {
    for (final descriptor in builtInAgentDescriptors) {
      expect(
        descriptor.binaries.forKind(EnvironmentKind.ssh),
        descriptor.binaries.posix,
      );
    }
  });

  test(
    'discovery finds a remote agent through the registry, unchanged',
    () async {
      final runner = FakeCommandRunner(
        environmentId: remote.id,
        responder: (req) {
          if (req.arguments.contains('command -v claude')) {
            return const CommandResult(
              exitCode: 0,
              stdout: '/home/dev/.local/bin/claude\n',
              stderr: '',
            );
          }
          if (req.executable == '/home/dev/.local/bin/claude') {
            return const CommandResult(
              exitCode: 0,
              stdout: '2.1.0 (Claude Code)\n',
              stderr: '',
            );
          }
          return const CommandResult(exitCode: 1, stdout: '', stderr: '');
        },
      );

      final found = await AgentDiscoveryService(
        runner: runner,
        environment: remote,
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
      ).discover();

      expect(found.map((i) => i.agentId), [AgentIds.claudeCode]);
      final claude = found.single;
      expect(claude.executable.path, '/home/dev/.local/bin/claude');
      // The installation is bound to the remote environment, so it can never be
      // confused with a local one at the same path (principle 2 / principle 4).
      expect(claude.executable.environmentId, 'ssh:h1');
      expect(claude.version, '2.1.0');
    },
  );

  test('an unreachable host reads as "no agents", not as an error', () async {
    final runner = FakeCommandRunner(
      environmentId: remote.id,
      throwError: CommandException('connection lost'),
    );
    final found = await AgentDiscoveryService(
      runner: runner,
      environment: remote,
      ids: SequentialIdGenerator(),
      clock: FixedClock(testTime),
    ).discover();
    expect(found, isEmpty);
  });
}
