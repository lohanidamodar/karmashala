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

  group('scrcpy-server deployment', () {
    // The bug this group exists for, seen on F6IZLV6LMFT4U4ZT: every start
    // pushed the jar to ONE fixed path, and scrcpy-server 4.1 deletes its own
    // jar as it starts (`unlinkSelf`). The `control=true` attempt therefore
    // removed the jar that the `control=false` retry needed, and that retry's
    // `app_process` died with
    // `ClassNotFoundException: com.genymobile.scrcpy.Server` — SIGABRT, adb
    // reporting "Aborted". Confirmed on the device from the crash log.
    test('every session gets its own jar, under one reapable prefix', () {
      final first = scrcpyJarPathFor('3f3c4fef');
      final second = scrcpyJarPathFor('12a9795f');
      expect(first, isNot(second));
      expect(first, startsWith(kScrcpyJarPathPrefix));
      expect(second, startsWith(kScrcpyJarPathPrefix));
      // Never the plain name a developer's own scrcpy uses: reaping matches on
      // the prefix, and must not be able to kill someone else's session.
      expect(kScrcpyJarPathPrefix, isNot('/data/local/tmp/scrcpy-server'));
    });

    test('each tunnel attempt re-pushes, so the retry finds a jar', () async {
      final runner = FakeCommandRunner(
        responder: (request) {
          if (request.arguments.contains('forward') &&
              request.arguments.contains('tcp:0')) {
            // A port nothing is listening on: every connect fails, so both
            // attempts run to exhaustion and `start` gives up.
            return const CommandResult(exitCode: 0, stdout: '1\n', stderr: '');
          }
          return const CommandResult(exitCode: 0, stdout: '', stderr: '');
        },
      );
      final service = DeviceStreamService(
        adb: AdbService(runner: runner, sdk: _sdk()),
        runner: runner,
        serverBytes: () async => Uint8List(4),
        socketAttempts: 1,
      );

      await expectLater(
        service.start('emulator-5554'),
        throwsA(isA<StateError>()),
      );

      final pushedTo = [
        for (final request in runner.requests)
          if (request.arguments.contains('push')) request.arguments.last,
      ];
      expect(
        pushedTo.length,
        2,
        reason: 'once for the control=true attempt, once for control=false',
      );
      expect(pushedTo.toSet().length, 2, reason: 'and never the same path');
      for (final path in pushedTo) {
        expect(path, startsWith(kScrcpyJarPathPrefix));
      }
    });

    test('a failed attempt takes its own jar off the device', () async {
      final runner = FakeCommandRunner(
        responder: (request) {
          if (request.arguments.contains('forward') &&
              request.arguments.contains('tcp:0')) {
            return const CommandResult(exitCode: 0, stdout: '1\n', stderr: '');
          }
          return const CommandResult(exitCode: 0, stdout: '', stderr: '');
        },
      );
      final service = DeviceStreamService(
        adb: AdbService(runner: runner, sdk: _sdk()),
        runner: runner,
        serverBytes: () async => Uint8List(4),
        socketAttempts: 1,
      );
      await expectLater(
        service.start('emulator-5554'),
        throwsA(isA<StateError>()),
      );

      // A server that never started never unlinked itself, and 700 KB per
      // failed attempt in /data/local/tmp adds up.
      final removed = [
        for (final request in runner.requests)
          if (request.arguments.contains('rm')) request.arguments.last,
      ];
      expect(removed.length, 2);
      for (final path in removed) {
        expect(path, startsWith(kScrcpyJarPathPrefix));
      }
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

    test('a device with nothing new to show is healthy, and stays up', () {
      // The distinction the restart loop turned on: frame silence is what an
      // untouched device looks like, so it is neither unhealthy nor a reason
      // to tear a working stream down.
      const idle = DeviceStreamHealth(
        state: DeviceStreamState.idle,
        detail: 'No screen changes for 20s.',
      );
      expect(idle.isHealthy, isTrue);
      expect(idle.needsRestart, isFalse);
      expect(
        const DeviceStreamHealth(
          state: DeviceStreamState.live,
          detail: 'Streaming.',
        ).isHealthy,
        isTrue,
      );
    });

    test('only a broken pipeline is worth a restart', () {
      for (final state in DeviceStreamState.values) {
        expect(
          DeviceStreamHealth(state: state, detail: '').needsRestart,
          state == DeviceStreamState.stalled ||
              state == DeviceStreamState.ended,
          reason: '$state',
        );
      }
    });
  });
}
