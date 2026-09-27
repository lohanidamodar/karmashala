import 'dart:typed_data';

import 'package:karmashala_remote/remote.dart' show kHostCompanionPort;
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_ssh_host/host.dart';
import 'package:test/test.dart';

class _Box implements HostDeployTarget {
  String firewall = 'none';
  String label = 'box.example';
  final ran = <String>[];

  @override
  String get address => label;

  @override
  Future<RemoteRun> run(String command) async {
    ran.add(command);
    return RemoteRun(0, '$firewall\n', '');
  }

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
    remotePath:
        '/home/x/.karmashala/bin/karmashala_host-1.0.0-linux-x64.d/bin/karmashala_host',
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

  test('the proof dials the machine, not the label ssh logs it under', () async {
    // What the real target answers: `user@host:22`, for logs. Dialling that is
    // a lookup failure, which read as "shut" on every real machine and sent a
    // firewall rule after a port that was open all along.
    final box = _Box()..label = 'dlohani@203.0.113.9:22';
    final dialled = <String>[];
    final setup = SshCompanionSetup(
      host: host,
      target: box,
      remotePath: '/x/karmashala_host',
      dial: (address, port, _) async {
        dialled.add('$address:$port');
        return true;
      },
    );

    final endpoint = await setup.prepare();

    expect(dialled, ['203.0.113.9:$kHostCompanionPort']);
    expect(endpoint.reachable, isTrue);
    expect(
      endpoint.reason,
      contains('203.0.113.9:$kHostCompanionPort answered'),
    );
    expect(endpoint.reason, isNot(contains('dlohani@')));
    expect(box.ran, isEmpty, reason: 'an open port changes nothing on the box');
  });

  test('the companion port is not the ssh port', () async {
    final endpoint = await setupWith(_Box(), [true]).prepare();

    expect(endpoint.port, kHostCompanionPort);
    expect(
      endpoint.port,
      isNot(host.port),
      reason:
          'frames go straight to the host; ssh only provisioned the machine',
    );
    expect(endpoint.authority, '203.0.113.9:$kHostCompanionPort');
  });

  test(
    'an unreachable port is still an endpoint, and says what to do',
    () async {
      final box = _Box()..firewall = 'nosudo-ufw';

      final endpoint = await setupWith(box, [false]).prepare();

      // The address and port are right; something between is not. A phone may
      // also sit somewhere this desktop does not, so this is not a refusal.
      expect(endpoint.address, '203.0.113.9');
      expect(endpoint.reachable, isFalse);
      expect(endpoint.reason, contains('$kHostCompanionPort'));
      // The command is its own field now, so a dialog can offer it to a terminal
      // rather than bury it in a sentence.
      expect(endpoint.reason, isNot(contains('Run: ')));
      expect(
        endpoint.privileged?.command,
        'sudo ufw allow $kHostCompanionPort/tcp',
      );
      expect(endpoint.outsideTheMachine, isFalse);
    },
  );

  test('checking again after the command was run names the provider', () async {
    final box = _Box()..firewall = 'nosudo-ufw';

    final endpoint = await setupWith(box, [
      false,
    ]).prepare(ruleAddedByHand: true);

    expect(endpoint.reachable, isFalse);
    expect(endpoint.privileged, isNull);
    expect(endpoint.outsideTheMachine, isTrue);
    expect(endpoint.reason, contains('security group'));
  });

  test('a port already open needs no remedy in its sentence', () async {
    final endpoint = await setupWith(_Box(), [true]).prepare();

    expect(endpoint.reason, contains('answered'));
    expect(endpoint.reason, isNot(contains('Run: ')));
  });
}
