import 'package:test/test.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_devices/src/data/adb_service.dart';
import 'package:karmashala_devices/src/domain/android_device.dart';
import 'package:karmashala_devices/src/domain/wireless_pairing.dart';

import './support/fake_command_runner.dart';

const _adbPath = r'C:\sdk\platform-tools\adb.exe';

AndroidSdk _sdk() => const AndroidSdk(
  root: EnvironmentPath(environmentId: 'windows', path: r'C:\sdk'),
  adb: EnvironmentPath(environmentId: 'windows', path: _adbPath),
);

CommandResult _out(String stdout, {int exitCode = 0}) =>
    CommandResult(exitCode: exitCode, stdout: stdout, stderr: '');

void main() {
  group('mdnsAvailability', () {
    test('asks adb, and once', () async {
      final runner = FakeCommandRunner(
        responder: (_) => _out('mdns daemon version [adb discovery 0.0.0]\n'),
      );
      final adb = AdbService(runner: runner, sdk: _sdk());

      expect(await adb.mdnsAvailability(), MdnsAvailability.available);
      expect(runner.requests, hasLength(1));
      expect(runner.requests.single.executable, _adbPath);
      expect(runner.requests.single.arguments, ['mdns', 'check']);
    });

    test('an adb that cannot be started is unknown, not unavailable', () async {
      final runner = FakeCommandRunner(
        throwError: CommandException('no adb here'),
      );
      final adb = AdbService(runner: runner, sdk: _sdk());

      expect(await adb.mdnsAvailability(), MdnsAvailability.unknown);
    });
  });

  group('mdnsServices', () {
    test('asks adb for the listing, and once', () async {
      final runner = FakeCommandRunner(
        responder: (_) => _out(
          'List of discovered mdns services\n'
          'karmashala-A1B2C3D4\t_adb-tls-pairing._tcp\t10.0.0.5:41733\n',
        ),
      );
      final adb = AdbService(runner: runner, sdk: _sdk());

      final scan = await adb.mdnsServices();
      expect(scan.services.single.port, 41733);
      expect(runner.requests, hasLength(1));
      expect(runner.requests.single.arguments, ['mdns', 'services']);
    });

    test('an adb that cannot be started reads as unknown', () async {
      final runner = FakeCommandRunner(
        throwError: CommandException('no adb here'),
      );
      final adb = AdbService(runner: runner, sdk: _sdk());

      final scan = await adb.mdnsServices();
      expect(scan.availability, MdnsAvailability.unknown);
      expect(
        scan.isReading,
        isFalse,
        reason: 'an empty list from a failed probe is not a reading of zero',
      );
    });
  });

  group('pair', () {
    test('passes the code as an argument so adb never prompts', () async {
      final runner = FakeCommandRunner(
        responder: (_) => _out(
          'Successfully paired to 10.0.0.5:41733 [guid=adb-SERIAL-abc]\n',
        ),
      );
      final adb = AdbService(runner: runner, sdk: _sdk());

      final result = await adb.pair(
        const PairingAddress(host: '10.0.0.5', port: 41733),
        code: '123456',
      );

      expect(result, isA<AdbPaired>());
      expect((result as AdbPaired).guid, 'adb-SERIAL-abc');
      expect(runner.requests.single.arguments, [
        'pair',
        '10.0.0.5:41733',
        '123456',
      ]);
    });

    test(
      'brackets an IPv6 host so its colons are not read as a port',
      () async {
        final runner = FakeCommandRunner(
          responder: (_) => _out('Failed: Unable to start pairing client.\n'),
        );
        final adb = AdbService(runner: runner, sdk: _sdk());

        await adb.pair(
          const PairingAddress(host: 'fe80::1', port: 41733),
          code: '123456',
        );
        expect(runner.requests.single.arguments[1], '[fe80::1]:41733');
      },
    );

    test('an adb that cannot be started is a refusal that says so', () async {
      final runner = FakeCommandRunner(
        throwError: CommandException('no adb here'),
      );
      final adb = AdbService(runner: runner, sdk: _sdk());

      final result = await adb.pair(
        const PairingAddress(host: '10.0.0.5', port: 41733),
        code: '123456',
      );
      expect(
        result,
        isA<AdbPairRefused>().having(
          (r) => r.cause,
          'cause',
          AdbPairFailure.unknown,
        ),
      );
    });

    test(
      'never starts a streaming process — pairing is run to completion',
      () async {
        final runner = FakeCommandRunner(
          responder: (_) =>
              _out('Successfully paired to 10.0.0.5:41733 [guid=adb-a-b]\n'),
        );
        final adb = AdbService(runner: runner, sdk: _sdk());

        await adb.pair(
          const PairingAddress(host: '10.0.0.5', port: 41733),
          code: '123456',
        );
        expect(
          runner.startRequests,
          isEmpty,
          reason: 'a streaming spawn is charged to the calling isolate',
        );
      },
    );
  });

  group('connect', () {
    test('asks adb to connect to the address it was given', () async {
      final runner = FakeCommandRunner(
        responder: (_) => _out('connected to 10.0.0.5:5555\n'),
      );
      final adb = AdbService(runner: runner, sdk: _sdk());

      expect(
        await adb.connect(const PairingAddress(host: '10.0.0.5', port: 5555)),
        AdbConnectOutcome.connected,
      );
      expect(runner.requests.single.arguments, ['connect', '10.0.0.5:5555']);
    });

    test('an adb that cannot be started is a refusal', () async {
      final runner = FakeCommandRunner(
        throwError: CommandException('no adb here'),
      );
      final adb = AdbService(runner: runner, sdk: _sdk());

      expect(
        await adb.connect(const PairingAddress(host: '10.0.0.5', port: 5555)),
        AdbConnectOutcome.refused,
      );
    });
  });
}
