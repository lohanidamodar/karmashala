import 'dart:typed_data';

import 'package:karmashala_host/protocol.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_ssh/host.dart';
import 'package:test/test.dart';

class _Box implements HostDeployTarget {
  String firewall = 'none';

  @override
  String get address => 'box.example';

  @override
  Future<RemoteRun> run(String command) async => RemoteRun(0, '$firewall\n', '');

  @override
  Future<void> upload(String remotePath, Uint8List bytes) async {}

  @override
  Future<RemoteChannel> exec(String command) => throw UnimplementedError();
}

void main() {
  final host = SshHost(
    id: 'h1',
    name: 'do-box',
    // The address the person typed to reach it. Nothing derives another.
    host: '203.0.113.9',
    port: 22,
    username: 'dlohani',
    authMethod: SshAuthMethod.privateKey,
    createdAt: DateTime.utc(2026, 9, 16),
  );

  SshCompanionSetup setupWith(_Box box, List<bool> dials) => SshCompanionSetup(
    host: host,
    target: box,
    remotePath: '/home/x/.karmashala/bin/karmashala_host-1.0.0-linux-x64.d/bin/karmashala_host',
    ports: CompanionPortSetup(
      target: box,
      clock: () => DateTime.utc(2026, 9, 16),
      dial: (_, _, _) async => dials.removeAt(0),
    ),
  );

  test('the endpoint carries the address the desktop connected with', () async {
    final endpoint = await setupWith(_Box(), [true]).prepare();

    expect(endpoint.address, '203.0.113.9');
    expect(endpoint.hostName, 'do-box');
    expect(endpoint.reachable, isTrue);
  });

  test('the companion port is not the ssh port', () async {
    final endpoint = await setupWith(_Box(), [true]).prepare();

    expect(endpoint.port, kHostCompanionPort);
    expect(
      endpoint.port,
      isNot(host.port),
      reason: 'frames go straight to the host; ssh only provisioned the machine',
    );
    expect(endpoint.authority, '203.0.113.9:$kHostCompanionPort');
  });

  test('an unreachable port is still an endpoint, and says what to do', () async {
    final box = _Box()..firewall = 'nosudo';

    final endpoint = await setupWith(box, [false]).prepare();

    // The address and port are right; something between is not. A phone may
    // also sit somewhere this desktop does not, so this is not a refusal.
    expect(endpoint.address, '203.0.113.9');
    expect(endpoint.reachable, isFalse);
    expect(endpoint.reason, contains('Run: '));
    expect(endpoint.reason, contains('$kHostCompanionPort'));
  });

  test('a port already open needs no remedy in its sentence', () async {
    final endpoint = await setupWith(_Box(), [true]).prepare();

    expect(endpoint.reason, contains('answered'));
    expect(endpoint.reason, isNot(contains('Run: ')));
  });
}
