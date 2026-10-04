import 'dart:async';
import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_acp/karmashala_acp.dart' show AgentInfo;
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_host/src/acp/acp_transport.dart';
import 'package:karmashala_host/src/acp/acp_version_probe.dart';
import 'package:test/test.dart';

import '../support/fake_command_runner.dart';
import 'acp_fixture.dart';

/// An ACP agent's version, read over the protocol: `initialize` asked,
/// `agentInfo.version` taken, the process ended — and nothing thrown when
/// the agent is slow, silent or dead. Every agent here is the fake, over
/// in-memory streams; no process runs.
void main() {
  final t0 = DateTime.utc(2026, 10, 2, 12);

  group('readAcpAgentVersion', () {
    test(
      'asks initialize, takes agentInfo.version and ends the process',
      () async {
        final agent = FakeAcpAgent(
          agentInfo: const AgentInfo(
            name: 'fake',
            title: 'Fake',
            version: '1.0.91',
          ),
        );
        final process = FakeAcpProcess(agent);

        final version = await readAcpAgentVersion(
          process.spawn,
          clientName: 'Karmashala',
          clientVersion: '9.9.9',
        );

        expect(version, '1.0.91');
        expect(agent.receivedMethods, ['initialize']);
        expect(agent.initializeParams!['clientInfo'], {
          'name': 'Karmashala',
          'version': '9.9.9',
        });
        expect(process.killed, isTrue);
      },
    );

    test('its stderr is drained while it talks, and let go after', () async {
      final agent = FakeAcpAgent(
        agentInfo: const AgentInfo(name: 'fake', version: '1.0.0'),
      );
      var listened = false;
      var cancelled = false;
      final errors = StreamController<String>(
        onListen: () => listened = true,
        onCancel: () => cancelled = true,
      );
      final version = await readAcpAgentVersion(
        () async => AcpTransport.streams(
          output: agent.toClient,
          input: agent.fromClient,
          exitCode: Completer<int>().future,
          errorLines: errors.stream,
          kill: agent.close,
        ),
      );
      await pump();
      expect(version, '1.0.0');
      expect(listened, isTrue);
      expect(cancelled, isTrue);
    });

    test('an agent that never answers is given up on, and ended', () async {
      final output = StreamController<List<int>>();
      final input = StreamController<List<int>>();
      // What the client wrote is read, as a process would read its stdin.
      final written = <List<int>>[];
      input.stream.listen(written.add);
      var killed = false;

      final version = await readAcpAgentVersion(
        () async => AcpTransport.streams(
          output: output.stream,
          input: input.sink,
          exitCode: Completer<int>().future,
          kill: () async {
            killed = true;
            unawaited(output.close());
          },
        ),
        timeout: const Duration(milliseconds: 100),
      );

      expect(version, isNull);
      expect(killed, isTrue);
      expect(written, isNotEmpty, reason: 'initialize was sent');
    });

    test('a process that dies before answering reads as no version', () async {
      final process = FakeAcpProcess(FakeAcpAgent());
      final version = await readAcpAgentVersion(() async {
        final transport = await process.spawn();
        await process.die(1);
        return transport;
      }, timeout: const Duration(seconds: 2));
      expect(version, isNull);
    });

    test('a spawn that fails reads as no version', () async {
      final version = await readAcpAgentVersion(
        () async => throw CommandException('no such file'),
        timeout: const Duration(seconds: 1),
      );
      expect(version, isNull);
    });
  });

  group('AcpVersionProbe', () {
    final row = AcpAgentRow(
      id: 'r1',
      name: 'Mine',
      command: 'mine',
      args: const ['--acp'],
      env: const {'A': '1'},
      createdAt: t0,
    );
    final descriptor = acpAgentAdapter(row).descriptor;
    final wsl = ExecutionEnvironment(
      id: 'wsl:Ubuntu',
      kind: EnvironmentKind.wsl,
      name: 'Ubuntu',
      wslDistribution: 'Ubuntu',
      createdAt: t0,
    );
    AgentInstallation installation({
      String environmentId = 'wsl:Ubuntu',
      String path = '/opt/runner/run-agent',
      List<String> leadingArguments = const ['-y', 'mine-pkg'],
    }) => AgentInstallation(
      id: 'i1',
      agentId: row.agentId,
      executable: EnvironmentPath(environmentId: environmentId, path: path),
      leadingArguments: leadingArguments,
      createdAt: t0,
    );

    test(
      'starts the installation in its environment — leading arguments, '
      'then the spec\'s, under its variables — and reads the version',
      () async {
        final agent = FakeAcpAgent(
          agentInfo: const AgentInfo(name: 'mine', version: '2.3.4'),
        );
        final runner = FakeCommandRunner(
          environmentId: wsl.id,
          processFactory: (_) => _AgentProcess(agent),
        );
        final probe = AcpVersionProbe(
          runnerFor: (environment) {
            expect(environment.id, wsl.id);
            return runner;
          },
          timeout: const Duration(seconds: 5),
          clientVersion: '1.2.3',
        );

        final version = await probe.read(installation(), descriptor, wsl);

        expect(version, '2.3.4');
        final request = runner.startRequests.single;
        expect(request.executable, '/opt/runner/run-agent');
        expect(request.arguments, ['-y', 'mine-pkg', '--acp']);
        expect(request.environment, {'A': '1'});
        expect(request.workingDirectory!.environmentId, wsl.id);
        expect(request.workingDirectory!.path, '/tmp');
        expect(agent.initializeParams!['clientInfo'], {
          'name': 'Karmashala',
          'version': '1.2.3',
        });
      },
    );

    test('an agent without an ACP spec, and a box the runners do not reach, '
        'are not asked', () async {
      final runner = FakeCommandRunner();
      final probe = AcpVersionProbe(runnerFor: (_) => runner);
      final terminal = AgentRegistry.builtIn.adapters
          .firstWhere((a) => a.acp == null)
          .descriptor;
      expect(await probe.read(installation(), terminal, wsl), isNull);
      final ssh = ExecutionEnvironment(
        id: 'ssh:h1',
        kind: EnvironmentKind.ssh,
        name: 'box',
        sshHostId: 'h1',
        createdAt: t0,
      );
      expect(
        await probe.read(installation(environmentId: ssh.id), descriptor, ssh),
        isNull,
      );
      expect(runner.startRequests, isEmpty);
    });

    test('a runner that cannot be made reads as no version', () async {
      final probe = AcpVersionProbe(
        runnerFor: (_) => throw StateError('no distribution'),
      );
      expect(await probe.read(installation(), descriptor, wsl), isNull);
    });
  });
}

/// A [ProcessHandle] whose stdio is a [FakeAcpAgent]'s: what a runner would
/// hand back had it started the agent.
final class _AgentProcess implements ProcessHandle {
  _AgentProcess(this.agent);

  final FakeAcpAgent agent;
  final _exit = Completer<int>();

  @override
  Stream<List<int>> get stdoutBytes => agent.toClient;

  @override
  Stream<String> get stdoutLines =>
      throw UnsupportedError('the probe reads bytes');

  @override
  Stream<String> get stderrLines => const Stream.empty();

  @override
  void writeLine(String line) => agent.fromClient.add(utf8.encode('$line\n'));

  @override
  Future<void> closeStdin() async {}

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Future<void> kill() async {
    if (!_exit.isCompleted) _exit.complete(137);
    await agent.close();
  }

  @override
  Future<void> interrupt() => kill();
}
