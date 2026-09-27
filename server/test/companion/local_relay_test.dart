/// The LAN relay the server hosts: start/stop, the port-taken error, LAN
/// address ranking, the honest reachability probe, the netsh firewall attempt,
/// and the lone timeout it must not have. Moved from the app's embedded relay
/// (`app/lib/src/features/remote/relay_local/`, gone) with it.
///
/// Everything binds 127.0.0.1 and no test runs a real netsh — the command
/// runner is always the fake.
library;

import 'dart:async';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:test/test.dart';

import '../support/fake_command_runner.dart';

/// A real ephemeral port that is free right now — for the tests that must
/// know the port before the relay binds it.
Future<int> freePort() async {
  final socket = await ServerSocket.bind('127.0.0.1', 0);
  final port = socket.port;
  await socket.close();
  return port;
}

ServerLocalRelay loopbackRelay({
  CommandRunner? firewall,
  String? executablePath,
}) => ServerLocalRelay(firewall: firewall, executablePath: executablePath);

Future<void> start(ServerLocalRelay relay, [int port = 0]) =>
    relay.ensureRunning(port: port, address: '127.0.0.1');

void main() {
  test('the default port is the relay package\'s own, and the config '
      'agrees', () {
    expect(kDefaultLocalRelayPort, 8787);
    expect(
      ServerSettings.resolve(
        file: ServerConfig.empty,
        flags: ServerConfig.empty,
        hostName: 'desk',
      ).localRelayPort,
      kDefaultLocalRelayPort,
    );
  });

  test('start serves a real relay; stop frees the port', () async {
    final relay = loopbackRelay();

    await start(relay);

    expect(relay.status.state, LocalRelayState.running);
    expect(relay.isRunning, isTrue);
    final port = relay.status.boundPort!;
    expect(port, greaterThan(0));
    // The server's relay is the real relay: /healthz answers.
    final client = HttpClient();
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/healthz'),
    );
    final response = await request.close();
    expect(response.statusCode, 200);
    client.close(force: true);
    // Bound to one address, it is dialled there.
    expect(relay.status.primaryUrl, Uri.parse('ws://127.0.0.1:$port'));
    expect(relay.status.toJson(), containsPair('state', 'running'));
    expect(relay.status.toJson(), containsPair('url', 'ws://127.0.0.1:$port'));

    await relay.stop();

    expect(relay.status.state, LocalRelayState.stopped);
    // The port is genuinely released, not merely reported so.
    final rebound = await ServerSocket.bind('127.0.0.1', port);
    await rebound.close();
  });

  test('an unchanged port does not restart a running relay', () async {
    final relay = loopbackRelay();
    final port = await freePort();
    await start(relay, port);
    addTearDown(relay.stop);

    await start(relay, port);

    expect(relay.status.boundPort, port);
    expect(relay.isRunning, isTrue);
  });

  test('a taken port is an error status, and freeing it heals', () async {
    final taken = await ServerSocket.bind('127.0.0.1', 0);
    final relay = loopbackRelay();

    await start(relay, taken.port);

    expect(relay.status.state, LocalRelayState.error);
    expect(relay.status.error, contains('${taken.port}'));
    expect(relay.status.error, contains('in use'));

    await taken.close();
    await start(relay, taken.port);

    expect(relay.status.state, LocalRelayState.running);
    await relay.stop();
  });

  group('LAN addresses, for a relay bound to every interface', () {
    test('all exposed, virtual adapters outranked', () async {
      // The owner's Windows shape: WSL and Hyper-V beside the real NIC.
      final endpoints = await lanEndpoints(
        port: 8787,
        interfaces: () async => [
          (name: 'vEthernet (WSL (Hyper-V firewall))', ip: '172.22.32.1'),
          (name: 'Wi-Fi', ip: '192.168.1.7'),
          (name: 'Ethernet', ip: '10.0.0.3'),
        ],
        probe: (ip, port) async => true,
      );

      expect(endpoints, hasLength(3));
      expect(endpoints.where((e) => e.primary).single.ip, '192.168.1.7');
      expect(endpoints.first.url, Uri.parse('ws://192.168.1.7:8787'));
      // The WSL adapter is ranked last even though its range is private.
      expect(endpoints.last.ip, '172.22.32.1');
    });

    test('an unreachable address is demoted, honestly flagged', () async {
      final endpoints = await lanEndpoints(
        port: 8787,
        interfaces: () async => [
          (name: 'Wi-Fi', ip: '192.168.1.7'),
          (name: 'Ethernet', ip: '10.0.0.3'),
        ],
        probe: (ip, port) async => ip != '192.168.1.7',
      );

      expect(endpoints.first.ip, '10.0.0.3');
      expect(
        endpoints.firstWhere((e) => e.ip == '192.168.1.7').reachable,
        isFalse,
      );
    });

    test('a machine with no LAN address has no endpoint', () async {
      final endpoints = await lanEndpoints(
        port: 8787,
        interfaces: () async => throw const SocketException('no interfaces'),
        probe: (ip, port) async => true,
      );
      expect(endpoints, isEmpty);
    });
  });

  group('the firewall rule', () {
    test('absent rule: show fails, add runs scoped to exe and port', () async {
      final runner = FakeCommandRunner(
        responder: (request) => request.arguments.contains('show')
            ? const CommandResult(exitCode: 1, stdout: '', stderr: '')
            : const CommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
      final relay = loopbackRelay(
        firewall: runner,
        executablePath: r'C:\apps\karmashala_host.exe',
      );
      await start(relay);
      addTearDown(relay.stop);

      expect(relay.status.firewallHint, isFalse);
      expect(runner.requests, hasLength(2));
      expect(runner.requests[0].executable, 'netsh');
      expect(runner.requests[0].arguments, contains('show'));
      final add = runner.requests[1].arguments;
      expect(add, contains('add'));
      expect(add, contains('name=$kFirewallRuleName'));
      expect(add, contains('dir=in'));
      expect(add, contains('action=allow'));
      expect(add, contains(r'program=C:\apps\karmashala_host.exe'));
      expect(add, contains('protocol=TCP'));
      expect(add, contains('localport=${relay.status.boundPort}'));
    });

    test('a refused add (no admin) is a hint, never a failure', () async {
      final runner = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'The requested operation requires elevation.',
        ),
      );
      final relay = loopbackRelay(firewall: runner);
      await start(relay);
      addTearDown(relay.stop);

      expect(relay.status.state, LocalRelayState.running);
      expect(relay.status.firewallHint, isTrue);
    });

    test('a rule already covering the port is left alone', () async {
      final port = await freePort();
      final runner = FakeCommandRunner(
        responder: (request) => request.arguments.contains('show')
            ? CommandResult(
                exitCode: 0,
                // The label is localised on non-English Windows; the number
                // is what the relay matches on.
                stdout: 'Regelname: $kFirewallRuleName\nLocalPort: $port\n',
                stderr: '',
              )
            : const CommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
      final relay = loopbackRelay(firewall: runner);
      await start(relay, port);
      addTearDown(relay.stop);

      expect(relay.status.firewallHint, isFalse);
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
      final relay = loopbackRelay(firewall: runner);
      await start(relay, port);
      addTearDown(relay.stop);

      expect(relay.status.firewallHint, isFalse);
      final verbs = [
        for (final request in runner.requests)
          request.arguments.firstWhere(
            (a) => a == 'show' || a == 'delete' || a == 'add',
          ),
      ];
      expect(verbs, ['show', 'delete', 'add']);
      expect(runner.requests.last.arguments, contains('localport=$port'));
    });

    test("the installer's own rule counts: no hint for a firewall that is "
        'already open', () async {
      final runner = FakeCommandRunner(
        responder: (request) {
          if (!request.arguments.contains('show')) {
            return const CommandResult(exitCode: 1, stdout: '', stderr: '');
          }
          if (request.arguments.contains('name=$kFirewallRuleName')) {
            return const CommandResult(exitCode: 1, stdout: '', stderr: '');
          }
          return const CommandResult(
            exitCode: 0,
            stdout:
                'Rule Name: Karmashala\n'
                'Program: C:\\Program Files\\Karmashala\\karmashala_host.exe\n'
                'LocalPort: Any\n',
            stderr: '',
          );
        },
      );
      final relay = loopbackRelay(
        firewall: runner,
        executablePath: r'C:\Program Files\Karmashala\karmashala_host.exe',
      );
      await start(relay);
      addTearDown(relay.stop);

      expect(relay.status.firewallHint, isFalse);
    });

    test('a netsh that cannot run at all is a hint, not a crash', () async {
      final runner = FakeCommandRunner(
        throwError: CommandException('netsh missing'),
      );
      final relay = loopbackRelay(firewall: runner);
      await start(relay);
      addTearDown(relay.stop);

      expect(relay.status.state, LocalRelayState.running);
      expect(relay.status.firewallHint, isTrue);
    });
  });

  group('the lone timeout', () {
    // Measured on the owner's machine when the relay was the app's: its
    // three rendezvous listeners were evicted and re-dialled every 120 s by
    // the relay package's two-minute lone timeout. Every lone socket on this
    // relay is the server's own listener, waiting for a phone that may be
    // away for hours.
    test('is none', () {
      expect(kLocalRelayLoneTimeout, Duration.zero);
    });

    test('a listener waiting alone is not hung up on, and the phone still '
        'meets it there later', () async {
      final relay = loopbackRelay();
      await start(relay);
      addTearDown(relay.stop);
      final url =
          'ws://127.0.0.1:${relay.status.boundPort}/v1/'
          '0123456789abcdef0123456789abcdef';

      final host = await WebSocket.connect(url);
      addTearDown(host.close);
      final hostClosed = Completer<void>();
      final fromPhone = <Object?>[];
      host.listen(fromPhone.add, onDone: hostClosed.complete);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(hostClosed.isCompleted, isFalse, reason: 'left waiting');

      final phone = await WebSocket.connect(url);
      addTearDown(phone.close);
      final first = phone.first;
      host.add([7]);
      expect(await first.timeout(const Duration(seconds: 5)), [7]);
    });

    test('a shared relay keeps its own — the default is not zero', () {
      expect(kDefaultLoneTimeout, isNot(Duration.zero));
    });
  });
}
