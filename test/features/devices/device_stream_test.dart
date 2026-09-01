import 'dart:typed_data';

import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/features/devices/data/adb_service.dart';
import 'package:karmashala/src/features/devices/domain/android_device.dart';
import 'package:karmashala/src/features/devices/data/device_stream.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';

AndroidSdk _sdk() => const AndroidSdk(
  root: EnvironmentPath(environmentId: 'windows', path: r'C:\sdk'),
  adb: EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\sdk\platform-tools\adb.exe',
  ),
);

void main() {
  group('parseForwardedPort', () {
    test('reads the port adb allocated for tcp:0', () {
      expect(parseForwardedPort('54321\n'), 54321);
    });

    test('ignores surrounding chatter', () {
      expect(
        parseForwardedPort('* daemon started successfully\n49152\n'),
        49152,
      );
    });

    test('returns null when adb printed no port', () {
      expect(parseForwardedPort(''), isNull);
      expect(parseForwardedPort('error: device offline'), isNull);
    });
  });

  group('reapOrphans', () {
    DeviceStreamService serviceOver(FakeCommandRunner runner) =>
        DeviceStreamService(
          adb: AdbService(runner: runner, sdk: _sdk()),
          runner: runner,
          serverBytes: () async => Uint8List(0),
        );

    test('kills our leaked servers and removes our stale forwards', () async {
      // Both leaks were observed on this machine at once: on a phone the server
      // had exited while its forward stayed registered, and on an emulator four
      // servers were alive because killing the host-side `adb shell` does not
      // kill the app_process it started.
      final runner = FakeCommandRunner(
        responder: (request) {
          if (request.arguments.contains('ps')) {
            return const CommandResult(
              exitCode: 0,
              stdout:
                  ' 11026 sh -c CLASSPATH=/data/local/tmp/'
                  'karmashala-scrcpy-server.jar app_process / '
                  'com.genymobile.scrcpy.Server 4.1 scid=3f3c4fef\n'
                  ' 11028 app_process / com.genymobile.scrcpy.Server 4.1 '
                  'scid=3f3c4fef\n',
              stderr: '',
            );
          }
          if (request.arguments.contains('--list')) {
            return const CommandResult(
              exitCode: 0,
              stdout: 'emulator-5554 tcp:57521 localabstract:scrcpy_12a9795f\n',
              stderr: '',
            );
          }
          return const CommandResult(exitCode: 0, stdout: '', stderr: '');
        },
      );

      final reaped = await serviceOver(runner).reapOrphans('emulator-5554');
      expect(reaped, 3, reason: 'two processes and one forward');

      final commands = runner.requests.map((r) => r.arguments).toList();
      expect(
        commands,
        contains(
          equals([
            '-s',
            'emulator-5554',
            'shell',
            'kill',
            '-9',
            '11026',
            '11028',
          ]),
        ),
      );
      expect(
        commands,
        contains(
          equals(['-s', 'emulator-5554', 'forward', '--remove', 'tcp:57521']),
        ),
      );
    });

    test('a clean device is left completely alone', () async {
      final runner = FakeCommandRunner(
        responder: (_) =>
            const CommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
      expect(await serviceOver(runner).reapOrphans('emulator-5554'), 0);
      // Only the two read-only queries.
      expect(runner.requests.length, 2);
    });
  });

  group('DeviceStreamHealth', () {
    test('separates a dead stream from one nothing is decoding', () {
      // The two look identical on screen — a frozen picture — and have
      // completely different causes, so the distinction is carried explicitly.
      const noBytes = DeviceStreamHealth(
        state: DeviceStreamState.stalled,
        detail: 'No data from the device for 6s.',
      );
      const notDecoding = DeviceStreamHealth(
        state: DeviceStreamState.stalled,
        detail: 'still sending data but no frame has decoded',
        bytesArriving: true,
      );
      expect(noBytes.bytesArriving, isFalse);
      expect(notDecoding.bytesArriving, isTrue);
      expect(noBytes.isHealthy, isFalse);
      expect(notDecoding.isHealthy, isFalse);
    });

    test('carries what the server said, which is otherwise thrown away', () {
      const ended = DeviceStreamHealth(
        state: DeviceStreamState.ended,
        detail: 'scrcpy-server exited (code 143).',
        serverLog: ['Terminated'],
      );
      expect(ended.serverLog, ['Terminated']);
      expect(ended.isHealthy, isFalse);
    });

    test('only the live state is healthy', () {
      expect(
        const DeviceStreamHealth(
          state: DeviceStreamState.live,
          detail: 'Streaming.',
        ).isHealthy,
        isTrue,
      );
    });
  });
}
