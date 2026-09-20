import 'dart:math';

import 'package:test/test.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_devices/src/data/adb_wireless_parsing.dart';
import 'package:karmashala_devices/src/domain/wireless_pairing.dart';

void main() {
  group('the QR invite', () {
    test('encodes the Wi-Fi-style string the phone scans', () {
      const invite = AdbPairingInvite(
        serviceName: 'karmashala-A1B2C3D4',
        password: 'p4ssw0rdp4ss',
      );
      expect(
        invite.encode(),
        'WIFI:T:ADB;S:karmashala-A1B2C3D4;P:p4ssw0rdp4ss;;',
      );
    });

    test('never carries its password into a log line', () {
      const invite = AdbPairingInvite(
        serviceName: 'karmashala-A1B2C3D4',
        password: 'p4ssw0rdp4ss',
      );
      expect('$invite', isNot(contains('p4ssw0rdp4ss')));
      expect('$invite', contains('karmashala-A1B2C3D4'));
    });

    test('draws both halves from characters the format cannot misread', () {
      final safe = RegExp(r'^[A-Za-z0-9-]+$');
      final random = Random(7);
      for (var i = 0; i < 200; i++) {
        final invite = AdbPairingInvite.generate(random: random);
        expect(safe.hasMatch(invite.serviceName), isTrue);
        expect(RegExp(r'^[A-Za-z0-9]+$').hasMatch(invite.password), isTrue);
        expect(invite.password.length, greaterThanOrEqualTo(12));
      }
    });

    test('two invites do not share a service name', () {
      final names = {
        for (var i = 0; i < 50; i++) AdbPairingInvite.generate().serviceName,
      };
      expect(names.length, 50);
    });
  });

  group('adb mdns check', () {
    test('a daemon version is an available reading', () {
      expect(
        parseMdnsCheck(
          const CommandResult(
            exitCode: 0,
            stdout: 'mdns daemon version [adb discovery 0.0.0]\n',
            stderr: '',
          ),
        ),
        MdnsAvailability.available,
      );
    });

    test('the openscreen backend answers the same way', () {
      expect(
        parseMdnsCheck(
          const CommandResult(
            exitCode: 0,
            stdout: 'mdns daemon version [Openscreen discovery 0.0.0]\n',
            stderr: '',
          ),
        ),
        MdnsAvailability.available,
      );
    });

    test('disabled discovery is a reading of "off", not of "nothing"', () {
      expect(
        parseMdnsCheck(
          const CommandResult(
            exitCode: 0,
            stdout: 'ERROR: mdns discovery disabled\n',
            stderr: '',
          ),
        ),
        MdnsAvailability.disabled,
      );
    });

    test('output nobody can read is unknown, never available', () {
      expect(
        parseMdnsCheck(
          const CommandResult(exitCode: 1, stdout: '', stderr: 'adb: usage'),
        ),
        MdnsAvailability.unknown,
      );
    });
  });

  group('adb mdns services', () {
    test('reads a tab-separated row into a service', () {
      final scan = parseMdnsServices(
        const CommandResult(
          exitCode: 0,
          stdout:
              'List of discovered mdns services\n'
              'adb-39121FDJH004YS-vWDbLo\t_adb-tls-connect._tcp\t'
              '192.168.1.24:37129\n',
          stderr: '',
        ),
      );
      expect(scan.availability, MdnsAvailability.available);
      expect(scan.services, hasLength(1));
      final service = scan.services.single;
      expect(service.name, 'adb-39121FDJH004YS-vWDbLo');
      expect(service.type, kAdbConnectServiceType);
      expect(service.host, '192.168.1.24');
      expect(service.port, 37129);
      expect(service.address, '192.168.1.24:37129');
    });

    test('keeps the pairing and connect types apart', () {
      final scan = parseMdnsServices(
        const CommandResult(
          exitCode: 0,
          stdout:
              'List of discovered mdns services\n'
              'karmashala-A1B2C3D4\t_adb-tls-pairing._tcp\t10.0.0.5:41733\n'
              'adb-XYZ-abc\t_adb-tls-connect._tcp\t10.0.0.5:5555\n',
          stderr: '',
        ),
      );
      expect(
        scan.ofType(kAdbPairingServiceType).single.port,
        41733,
        reason: 'pairing and connecting are different ports on one phone',
      );
      expect(scan.ofType(kAdbConnectServiceType).single.port, 5555);
      expect(
        scan
            .find(type: kAdbPairingServiceType, name: 'karmashala-A1B2C3D4')
            ?.port,
        41733,
      );
      expect(
        scan.find(type: kAdbConnectServiceType, name: 'karmashala-A1B2C3D4'),
        isNull,
        reason: 'the name alone would find the pairing port here',
      );
      expect(scan.find(type: kAdbPairingServiceType, name: 'nobody'), isNull);
    });

    test('a trailing dot on the service type still matches', () {
      final scan = parseMdnsServices(
        const CommandResult(
          exitCode: 0,
          stdout:
              'List of discovered mdns services\n'
              'karmashala-A1B2C3D4\t_adb-tls-pairing._tcp.\t10.0.0.5:41733\n',
          stderr: '',
        ),
      );
      expect(scan.ofType(kAdbPairingServiceType), hasLength(1));
    });

    test('an empty listing is a reading of nothing', () {
      final scan = parseMdnsServices(
        const CommandResult(
          exitCode: 0,
          stdout: 'List of discovered mdns services\n',
          stderr: '',
        ),
      );
      expect(scan.availability, MdnsAvailability.available);
      expect(scan.services, isEmpty);
      expect(scan.isReading, isTrue);
    });

    test('disabled discovery is not an empty list', () {
      final scan = parseMdnsServices(
        const CommandResult(
          exitCode: 0,
          stdout: 'ERROR: mdns discovery disabled\n',
          stderr: '',
        ),
      );
      expect(scan.availability, MdnsAvailability.disabled);
      expect(scan.isReading, isFalse);
    });

    test('an IPv6 address keeps its colons and loses only the port', () {
      final scan = parseMdnsServices(
        const CommandResult(
          exitCode: 0,
          stdout:
              'List of discovered mdns services\n'
              'adb-XYZ-abc\t_adb-tls-connect._tcp\tfe80::1c2d:3e4f:5a6b:7c8d:5555\n',
          stderr: '',
        ),
      );
      expect(scan.services.single.host, 'fe80::1c2d:3e4f:5a6b:7c8d');
      expect(scan.services.single.port, 5555);
    });

    test('daemon chatter and malformed rows are dropped, not guessed at', () {
      final scan = parseMdnsServices(
        const CommandResult(
          exitCode: 0,
          stdout:
              '* daemon not running; starting now at tcp:5037\n'
              '* daemon started successfully\n'
              'List of discovered mdns services\n'
              'half-a-row\t_adb-tls-connect._tcp\n'
              'no-port\t_adb-tls-connect._tcp\t10.0.0.5\n'
              'ok\t_adb-tls-connect._tcp\t10.0.0.5:5555\n',
          stderr: '',
        ),
      );
      expect(scan.services.map((s) => s.name), ['ok']);
    });
  });

  group('adb pair', () {
    test('a success carries the address and the guid', () {
      final result = parsePairResult(
        const CommandResult(
          exitCode: 0,
          stdout:
              'Successfully paired to 192.168.1.24:41733 '
              '[guid=adb-39121FDJH004YS-vWDbLo]\n',
          stderr: '',
        ),
      );
      expect(
        result,
        isA<AdbPaired>()
            .having((p) => p.host, 'host', '192.168.1.24')
            .having((p) => p.port, 'port', 41733)
            .having((p) => p.guid, 'guid', 'adb-39121FDJH004YS-vWDbLo'),
      );
    });

    test('a wrong code says the code was wrong', () {
      final result = parsePairResult(
        const CommandResult(
          exitCode: 1,
          stdout: 'Failed: Wrong password or connection was dropped.\n',
          stderr: '',
        ),
      );
      expect(
        result,
        isA<AdbPairRefused>().having(
          (p) => p.cause,
          'cause',
          AdbPairFailure.wrongCode,
        ),
      );
      expect((result as AdbPairRefused).message, contains('pairing code'));
    });

    test('an unanswered pairing port names both of its reasons', () {
      final result = parsePairResult(
        const CommandResult(
          exitCode: 1,
          stdout: 'Failed: Unable to start pairing client.\n',
          stderr: '',
        ),
      );
      final refused = result as AdbPairRefused;
      expect(refused.cause, AdbPairFailure.unreachable);
      // Both of the two situations one adb message covers.
      expect(refused.message.toLowerCase(), contains('closed'));
      expect(refused.message.toLowerCase(), contains('network'));
    });

    test('a mistyped address is reported as an address, not as a refusal', () {
      final result = parsePairResult(
        const CommandResult(
          exitCode: 1,
          stdout: 'Failed to parse address for pairing: nonsense\n',
          stderr: '',
        ),
      );
      expect((result as AdbPairRefused).cause, AdbPairFailure.malformedAddress);
    });

    test('a missing code is its own failure', () {
      final result = parsePairResult(
        const CommandResult(
          exitCode: 1,
          stdout: 'No pairing code provided\n',
          stderr: '',
        ),
      );
      expect((result as AdbPairRefused).cause, AdbPairFailure.noCode);
    });

    test('an answer nobody recognises is never read as success', () {
      final result = parsePairResult(
        const CommandResult(exitCode: 1, stdout: '', stderr: 'boom'),
      );
      expect(result, isA<AdbPairRefused>());
      final refused = result as AdbPairRefused;
      expect(refused.cause, AdbPairFailure.unknown);
      expect(refused.message, isNotEmpty);
    });
  });

  group('adb connect', () {
    test('a fresh connection is a connection', () {
      expect(
        parseConnectResult(
          const CommandResult(
            exitCode: 0,
            stdout: 'connected to 192.168.1.24:5555\n',
            stderr: '',
          ),
        ),
        AdbConnectOutcome.connected,
      );
    });

    test('adb having got there first is also a connection', () {
      expect(
        parseConnectResult(
          const CommandResult(
            exitCode: 0,
            stdout: 'already connected to 192.168.1.24:5555\n',
            stderr: '',
          ),
        ),
        AdbConnectOutcome.connected,
      );
    });

    test('a refusal is a refusal', () {
      expect(
        parseConnectResult(
          const CommandResult(
            exitCode: 1,
            stdout: 'failed to connect to 192.168.1.24:5555\n',
            stderr: '',
          ),
        ),
        AdbConnectOutcome.refused,
      );
    });

    test('exit 0 with nothing recognisable is unknown, not connected', () {
      expect(
        parseConnectResult(
          const CommandResult(exitCode: 0, stdout: '', stderr: ''),
        ),
        AdbConnectOutcome.unknown,
      );
    });
  });

  group('the typed pairing address', () {
    test('accepts host:port', () {
      final parsed = parsePairingAddress('192.168.1.24:41733');
      expect(parsed?.host, '192.168.1.24');
      expect(parsed?.port, 41733);
    });

    test('accepts a bracketed IPv6 host', () {
      final parsed = parsePairingAddress('[fe80::1]:41733');
      expect(parsed?.host, 'fe80::1');
      expect(parsed?.port, 41733);
    });

    test('rejects a bare host, because the port is the whole point', () {
      expect(parsePairingAddress('192.168.1.24'), isNull);
    });

    test('rejects a port that is not one', () {
      expect(parsePairingAddress('192.168.1.24:0'), isNull);
      expect(parsePairingAddress('192.168.1.24:70000'), isNull);
      expect(parsePairingAddress('192.168.1.24:abc'), isNull);
    });

    test('rejects nothing at all', () {
      expect(parsePairingAddress('   '), isNull);
    });
  });

  group('the pairing code the user types', () {
    test('six digits is a code', () {
      expect(isPlausiblePairingCode('123456'), isTrue);
    });

    test('spaces around it are the user, not the code', () {
      expect(isPlausiblePairingCode('  123456 '), isTrue);
    });

    test('anything else is not', () {
      expect(isPlausiblePairingCode('12345'), isFalse);
      expect(isPlausiblePairingCode('1234567'), isFalse);
      expect(isPlausiblePairingCode('12345a'), isFalse);
      expect(isPlausiblePairingCode(''), isFalse);
    });
  });
}
