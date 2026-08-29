import 'dart:typed_data';

import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/features/devices/data/adb_service.dart';
import 'package:chitragupta/src/features/devices/domain/android_device.dart';
import 'package:chitragupta/src/features/devices/domain/device_input.dart';
import 'package:chitragupta/src/features/devices/domain/logcat_entry.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';

const _adbPath = r'C:\sdk\platform-tools\adb.exe';
const _emulatorPath = r'C:\sdk\emulator\emulator.exe';

AndroidSdk _sdk({bool withEmulator = true}) => AndroidSdk(
  root: const EnvironmentPath(environmentId: 'windows', path: r'C:\sdk'),
  adb: const EnvironmentPath(environmentId: 'windows', path: _adbPath),
  emulator: withEmulator
      ? const EnvironmentPath(environmentId: 'windows', path: _emulatorPath)
      : null,
);

/// The argv of the nth request, for asserting exact command lines — these are
/// the strings that fail silently when wrong.
List<String> _argv(FakeCommandRunner runner, int index) =>
    runner.requests[index].arguments;

void main() {
  group('encodeInputText', () {
    test('encodes spaces as %s, which is what Android input expects', () {
      expect(encodeInputText('hello world'), 'hello%sworld');
    });

    test('escapes shell metacharacters that would otherwise be interpreted', () {
      expect(encodeInputText(r'a&b'), r'a\&b');
      expect(encodeInputText('a"b'), r'a\"b');
      expect(encodeInputText(r"it's"), r"it\'s");
      expect(encodeInputText(r'$HOME'), r'\$HOME');
    });

    test('leaves ordinary text untouched', () {
      expect(encodeInputText('flutter123'), 'flutter123');
    });
  });

  group('listDevices', () {
    test('asks adb for the long listing and binds results to the environment',
        () async {
      final runner = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 0,
          stdout: 'List of devices attached\n'
              'emulator-5554  device product:sdk model:Pixel transport_id:7\n',
          stderr: '',
        ),
      );
      final devices =
          await AdbService(runner: runner, sdk: _sdk()).listDevices();

      expect(runner.requests.single.executable, _adbPath);
      expect(_argv(runner, 0), ['devices', '-l']);
      expect(devices.single.serial, 'emulator-5554');
      expect(devices.single.environmentId, 'windows');
    });

    test('returns empty rather than throwing when adb fails', () async {
      final runner = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'no devices',
        ),
      );
      expect(
        await AdbService(runner: runner, sdk: _sdk()).listDevices(),
        isEmpty,
      );
    });
  });

  group('input', () {
    test('tap sends the exact adb argv', () async {
      final runner = FakeCommandRunner();
      await AdbService(runner: runner, sdk: _sdk()).tap('S1', 100, 250);
      expect(_argv(runner, 0),
          ['-s', 'S1', 'shell', 'input', 'tap', '100', '250']);
    });

    test('swipe passes the duration in milliseconds', () async {
      final runner = FakeCommandRunner();
      await AdbService(runner: runner, sdk: _sdk()).swipe(
        'S1',
        fromX: 1, fromY: 2, toX: 3, toY: 4,
        duration: const Duration(milliseconds: 350),
      );
      expect(_argv(runner, 0), [
        '-s', 'S1', 'shell', 'input', 'swipe', '1', '2', '3', '4', '350',
      ]);
    });

    test('pressKey maps the enum to an Android keycode', () async {
      final runner = FakeCommandRunner();
      await AdbService(runner: runner, sdk: _sdk())
          .pressKey('S1', DeviceKey.recents);
      expect(_argv(runner, 0),
          ['-s', 'S1', 'shell', 'input', 'keyevent', 'KEYCODE_APP_SWITCH']);
    });

    test('inputText encodes before sending', () async {
      final runner = FakeCommandRunner();
      await AdbService(runner: runner, sdk: _sdk())
          .inputText('S1', 'hi there');
      expect(_argv(runner, 0),
          ['-s', 'S1', 'shell', 'input', 'text', 'hi%sthere']);
    });

    test('sends nothing for empty text', () async {
      final runner = FakeCommandRunner();
      await AdbService(runner: runner, sdk: _sdk()).inputText('S1', '');
      expect(runner.requests, isEmpty);
    });

    test('surfaces a failed input rather than failing silently', () async {
      final runner = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'device offline',
        ),
      );
      expect(
        () => AdbService(runner: runner, sdk: _sdk()).tap('S1', 1, 1),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('screenshot', () {
    test('captures to the device, pulls it, then cleans up', () async {
      final runner = FakeCommandRunner();
      final bytes = await AdbService(
        runner: runner,
        sdk: _sdk(),
        readHostFile: (path) async => Uint8List.fromList([0x89, 0x50]),
      ).screenshot('S1', hostPath: r'C:\tmp\shot.png');

      expect(_argv(runner, 0), [
        '-s', 'S1', 'shell', 'screencap', '-p',
        '/data/local/tmp/chitragupta_screen.png',
      ]);
      expect(_argv(runner, 1), [
        '-s', 'S1', 'pull',
        '/data/local/tmp/chitragupta_screen.png', r'C:\tmp\shot.png',
      ]);
      expect(_argv(runner, 2).sublist(2),
          ['shell', 'rm', '-f', '/data/local/tmp/chitragupta_screen.png']);
      expect(bytes, [0x89, 0x50]);
    });

    test('reports a failed capture', () async {
      final runner = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 1, stdout: '', stderr: 'permission denied',
        ),
      );
      expect(
        () => AdbService(runner: runner, sdk: _sdk())
            .screenshot('S1', hostPath: 'x.png'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('logcat', () {
    test('filters to the package pids', () async {
      final runner = FakeCommandRunner(
        responder: (request) {
          if (request.arguments.contains('pidof')) {
            return const CommandResult(
              exitCode: 0, stdout: '1234 5678', stderr: '',
            );
          }
          return const CommandResult(
            exitCode: 0,
            stdout: '08-29 20:15:33.123  1234  5678 I MyTag   : hello\n'
                '08-29 20:15:34.000  1234  5678 D Other   : noise\n',
            stderr: '',
          );
        },
      );
      final entries = await AdbService(runner: runner, sdk: _sdk())
          .readLogcat('S1', packageName: 'com.example.app');

      expect(_argv(runner, 0).sublist(2), ['shell', 'pidof', 'com.example.app']);
      expect(_argv(runner, 1), containsAllInOrder(
          ['shell', 'logcat', '-d', '-v', 'threadtime']));
      expect(_argv(runner, 1), containsAllInOrder(['--pid', '1234']));
      expect(entries, hasLength(2));
      expect(entries.first.tag, 'MyTag');
    });

    test('returns empty when the package is not running, not the whole log',
        () async {
      final runner = FakeCommandRunner(
        responder: (request) => request.arguments.contains('pidof')
            ? const CommandResult(exitCode: 1, stdout: '', stderr: '')
            : const CommandResult(exitCode: 0, stdout: 'lots of noise', stderr: ''),
      );
      final entries = await AdbService(runner: runner, sdk: _sdk())
          .readLogcat('S1', packageName: 'com.absent.app');
      expect(entries, isEmpty);
      expect(runner.requests, hasLength(1), reason: 'must not run logcat at all');
    });

    test('applies the minimum level filter', () async {
      final runner = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 0,
          stdout: '08-29 20:15:33.123  1  2 V A: verbose\n'
              '08-29 20:15:33.124  1  2 E B: error\n',
          stderr: '',
        ),
      );
      final entries = await AdbService(runner: runner, sdk: _sdk())
          .readLogcat('S1', minLevel: LogLevel.error);
      expect(entries, hasLength(1));
      expect(entries.single.level, LogLevel.error);
    });
  });

  group('AVDs', () {
    test('lists AVDs and marks the running one', () async {
      final runner = FakeCommandRunner(
        responder: (request) {
          if (request.executable == _emulatorPath) {
            return const CommandResult(
              exitCode: 0, stdout: 'Pixel_8_Pro\nsambandha_test\n', stderr: '',
            );
          }
          if (request.arguments.contains('devices')) {
            return const CommandResult(
              exitCode: 0,
              stdout: 'List of devices attached\nemulator-5554 device\n',
              stderr: '',
            );
          }
          // `emu avd name` answers with the name then OK.
          return const CommandResult(
            exitCode: 0, stdout: 'sambandha_test\nOK\n', stderr: '',
          );
        },
      );
      final avds = await AdbService(runner: runner, sdk: _sdk()).listAvds();
      expect(avds.map((a) => a.name), ['Pixel_8_Pro', 'sambandha_test']);
      expect(avds[0].isRunning, isFalse);
      expect(avds[1].runningSerial, 'emulator-5554');
    });

    test('returns no AVDs when the SDK has no emulator package', () async {
      final runner = FakeCommandRunner();
      final avds = await AdbService(runner: runner, sdk: _sdk(withEmulator: false))
          .listAvds();
      expect(avds, isEmpty);
      expect(runner.requests, isEmpty);
    });

    test('booting without an emulator package explains why', () async {
      expect(
        () => AdbService(runner: FakeCommandRunner(), sdk: _sdk(withEmulator: false))
            .bootAvd('X'),
        throwsA(isA<StateError>()),
      );
    });

    test('boots an AVD as a long-lived process', () async {
      final runner = FakeCommandRunner();
      await AdbService(runner: runner, sdk: _sdk()).bootAvd('Pixel_8_Pro');
      expect(runner.startRequests.single.executable, _emulatorPath);
      expect(runner.startRequests.single.arguments, ['-avd', 'Pixel_8_Pro']);
    });
  });

  group('screenSize', () {
    test('reads the device coordinate space', () async {
      final runner = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 0, stdout: 'Physical size: 1080x2400', stderr: '',
        ),
      );
      final size = await AdbService(runner: runner, sdk: _sdk()).screenSize('S1');
      expect(size, const DeviceScreenSize(width: 1080, height: 2400));
    });
  });
}
