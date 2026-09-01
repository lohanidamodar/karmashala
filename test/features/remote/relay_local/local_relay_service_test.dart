/// The embedded local relay: start/stop, the port-taken error, LAN address
/// ranking, the honest reachability probe, and the netsh firewall attempt.
///
/// Everything binds 127.0.0.1 and no test runs a real netsh — the command
/// runner is always the fake.
library;

import 'dart:io';

import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/features/remote/relay_local/local_relay_service.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_command_runner.dart';

/// A real ephemeral port that is free right now — for the tests that must
/// know the port before the service binds it.
Future<int> freePort() async {
  final socket = await ServerSocket.bind('127.0.0.1', 0);
  final port = socket.port;
  await socket.close();
  return port;
}

LocalRelayService loopbackService({
  LanInterfaceLister? interfaces,
  ReachabilityProbe? probe,
  CommandRunner? firewall,
  String? executablePath,
}) => LocalRelayService(
  bindAddress: '127.0.0.1',
  interfaces: interfaces ?? () async => [(name: 'lo', ip: '127.0.0.1')],
  probe: probe,
  firewall: firewall,
  executablePath: executablePath,
);

void main() {
  test('the default port is the relay package\'s own, and Settings agrees', () {
    expect(kDefaultLocalRelayPort, 8787);
    expect(const Settings().localRelayPort, kDefaultLocalRelayPort);
  });

  test('start serves a real relay; stop frees the port', () async {
    final service = loopbackService();
    final seen = <LocalRelayState>[];
    final subscription = service.changes.listen(
      (status) => seen.add(status.state),
    );
    addTearDown(subscription.cancel);

    await service.ensureRunning(0);

    expect(service.status.state, LocalRelayState.running);
    expect(service.isRunning, isTrue);
    final port = service.status.boundPort!;
    expect(port, greaterThan(0));
    // The embedded server is the real relay: /healthz answers.
    final client = HttpClient();
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/healthz'),
    );
    final response = await request.close();
    expect(response.statusCode, 200);
    client.close(force: true);
    // The real probe self-connected, so the one endpoint is reachable.
    expect(service.status.primaryUrl, Uri.parse('ws://127.0.0.1:$port'));
    expect(service.status.endpoints.single.reachable, isTrue);

    await service.stop();
    await pumpEventQueue(); // broadcast-stream delivery is a microtask away

    expect(service.status.state, LocalRelayState.stopped);
    expect(seen, [LocalRelayState.running, LocalRelayState.stopped]);
    // The port is genuinely released, not merely reported so.
    final rebound = await ServerSocket.bind('127.0.0.1', port);
    await rebound.close();
  });

  test('an unchanged port does not restart a running relay', () async {
    final service = loopbackService();
    await service.ensureRunning(0);
    addTearDown(service.stop);
    final port = service.status.boundPort;

    await service.ensureRunning(0);

    expect(service.status.boundPort, port);
  });

  test('a taken port is an error status, and freeing it heals', () async {
    final taken = await ServerSocket.bind('127.0.0.1', 0);
    final service = loopbackService();

    await service.ensureRunning(taken.port);

    expect(service.status.state, LocalRelayState.error);
    expect(service.status.error, contains('${taken.port}'));
    expect(service.status.error, contains('in use'));

    await taken.close();
    await service.ensureRunning(taken.port);

    expect(service.status.state, LocalRelayState.running);
    await service.stop();
  });

  test('LAN addresses: all exposed, virtual adapters outranked', () async {
    // This machine's own shape: WSL and Hyper-V adapters beside the real NIC.
    final service = loopbackService(
      interfaces: () async => [
        (name: 'vEthernet (WSL (Hyper-V firewall))', ip: '172.22.32.1'),
        (name: 'Wi-Fi', ip: '192.168.1.7'),
        (name: 'Ethernet', ip: '10.0.0.3'),
      ],
      probe: (ip, port) async => true,
    );
    await service.ensureRunning(0);
    addTearDown(service.stop);

    final status = service.status;
    final port = status.boundPort!;
    expect(status.endpoints, hasLength(3));
    expect(status.primaryUrl, Uri.parse('ws://192.168.1.7:$port'));
    expect(status.endpoints.where((e) => e.primary).single.ip, '192.168.1.7');
    expect(
      status.endpoints.map((e) => '${e.url}'),
      containsAll([
        'ws://192.168.1.7:$port',
        'ws://10.0.0.3:$port',
        'ws://172.22.32.1:$port',
      ]),
    );
    // The WSL adapter is ranked last even though its range is private.
    expect(status.endpoints.last.ip, '172.22.32.1');
  });

  test('an unreachable address is demoted, honestly flagged', () async {
    final service = loopbackService(
      interfaces: () async => [
        (name: 'Wi-Fi', ip: '192.168.1.7'),
        (name: 'Ethernet', ip: '10.0.0.3'),
      ],
      probe: (ip, port) async => ip != '192.168.1.7',
    );
    await service.ensureRunning(0);
    addTearDown(service.stop);

    final status = service.status;
    expect(status.primaryUrl!.host, '10.0.0.3');
    expect(
      status.endpoints.firstWhere((e) => e.ip == '192.168.1.7').reachable,
      isFalse,
    );
  });

  test('a machine with no LAN address still runs, with no primary', () async {
    final service = loopbackService(
      interfaces: () async => throw const SocketException('no interfaces'),
    );
    await service.ensureRunning(0);
    addTearDown(service.stop);

    expect(service.status.state, LocalRelayState.running);
    expect(service.status.endpoints, isEmpty);
    expect(service.status.primaryUrl, isNull);
  });

  group('the firewall rule', () {
    test('absent rule: show fails, add runs scoped to exe and port', () async {
      final runner = FakeCommandRunner(
        responder: (request) => request.arguments.contains('show')
            ? const CommandResult(exitCode: 1, stdout: '', stderr: '')
            : const CommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
      final service = loopbackService(
        firewall: runner,
        executablePath: r'C:\apps\karmashala.exe',
      );
      await service.ensureRunning(0);
      addTearDown(service.stop);

      expect(service.status.firewallHint, isFalse);
      expect(runner.requests, hasLength(2));
      expect(runner.requests[0].executable, 'netsh');
      expect(runner.requests[0].arguments, contains('show'));
      final add = runner.requests[1].arguments;
      expect(add, contains('add'));
      expect(add, contains('name=$kFirewallRuleName'));
      expect(add, contains('dir=in'));
      expect(add, contains('action=allow'));
      expect(add, contains(r'program=C:\apps\karmashala.exe'));
      expect(add, contains('protocol=TCP'));
      expect(add, contains('localport=${service.status.boundPort}'));
    });

    test('a refused add (no admin) is a hint, never a failure', () async {
      final runner = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'The requested operation requires elevation.',
        ),
      );
      final service = loopbackService(firewall: runner);
      await service.ensureRunning(0);
      addTearDown(service.stop);

      expect(service.status.state, LocalRelayState.running);
      expect(service.status.firewallHint, isTrue);
    });

    test('a rule already covering the port is left alone', () async {
      final port = await freePort();
      final runner = FakeCommandRunner(
        responder: (request) => request.arguments.contains('show')
            ? CommandResult(
                exitCode: 0,
                // The label is localised on non-English Windows; the number
                // is what the service matches on.
                stdout: 'Regelname: $kFirewallRuleName\nLocalPort: $port\n',
                stderr: '',
              )
            : const CommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
      final service = loopbackService(firewall: runner);
      await service.ensureRunning(port);
      addTearDown(service.stop);

      expect(service.status.firewallHint, isFalse);
      expect(runner.requests, hasLength(1), reason: 'show only — no add');
    });

    test('a rule for another port is replaced', () async {
      final port = await freePort();
      final runner = FakeCommandRunner(
        responder: (request) => request.arguments.contains('show')
            ? const CommandResult(
                exitCode: 0,
                stdout: 'LocalPort: 9999\n',
                stderr: '',
              )
            : const CommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
      final service = loopbackService(firewall: runner);
      await service.ensureRunning(port);
      addTearDown(service.stop);

      expect(service.status.firewallHint, isFalse);
      final verbs = [
        for (final request in runner.requests)
          request.arguments.firstWhere(
            (a) => a == 'show' || a == 'delete' || a == 'add',
          ),
      ];
      expect(verbs, ['show', 'delete', 'add']);
      expect(runner.requests.last.arguments, contains('localport=$port'));
    });

    test('a netsh that cannot run at all is a hint, not a crash', () async {
      final runner = FakeCommandRunner(
        throwError: CommandException('netsh missing'),
      );
      final service = loopbackService(firewall: runner);
      await service.ensureRunning(0);
      addTearDown(service.stop);

      expect(service.status.state, LocalRelayState.running);
      expect(service.status.firewallHint, isTrue);
    });
  });
}
