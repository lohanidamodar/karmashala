import 'dart:convert';

import 'package:test/test.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_devices/src/data/adb_device_driver.dart';
import 'package:karmashala_devices/src/data/adb_service.dart';
import 'package:karmashala_devices/src/data/simctl_service.dart';
import 'package:karmashala_devices/src/data/simulator_device_driver.dart';
import 'package:karmashala_devices/src/domain/android_device.dart';
import 'package:karmashala_devices/src/domain/device_driver.dart';
import 'package:karmashala_devices/src/domain/device_target.dart';
import 'package:karmashala_devices/src/domain/ios_simulator.dart';

import './support/fake_command_runner.dart';

/// Copying and moving *within* a device: no host round trip, and every refusal
/// the surface is meant to give. These assert on the **device command line**,
/// which is what silently does the wrong thing when the quoting is wrong.
const _serial = 'emulator-5554';

AndroidSdk _sdk() => const AndroidSdk(
  root: EnvironmentPath(environmentId: 'windows', path: r'C:\sdk'),
  adb: EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\sdk\platform-tools\adb.exe',
  ),
);

AdbDeviceDriver _driver(AdbService adb) => AdbDeviceDriver(
  adb: adb,
  target: AndroidTarget(
    const AndroidDevice(
      serial: _serial,
      environmentId: 'windows',
      state: DeviceConnectionState.device,
    ),
  ),
);

CommandResult _out(String stdout) =>
    CommandResult(exitCode: 0, stdout: stdout, stderr: '');

/// Device text as the service reads it back: base64, because anything holding
/// filenames is piped through it. See `AdbService._readDeviceText`.
CommandResult _lsOut(String listing) =>
    _out(base64.encode(utf8.encode(listing)));

/// A device whose `ls -lad` answers are scripted per path, and whose `cp`/`mv`
/// say nothing — which is what success looks like for both.
FakeCommandRunner _runner(Map<String, String> stats, {String? failWith}) =>
    FakeCommandRunner(
      responder: (request) {
        final command = request.arguments.last;
        for (final entry in stats.entries) {
          if (command.contains("ls -lad '${entry.key}'")) {
            return _lsOut(entry.value);
          }
        }
        if (command.startsWith('ls -lad ')) {
          // Nothing there. `classifyLsFailure` reads this as `missing`, and
          // `statPath` turns it into null rather than a refusal.
          return _lsOut(
            'ls: ${request.arguments.last}: No such file or '
            'directory',
          );
        }
        if (failWith != null &&
            (command.startsWith('cp ') || command.startsWith('mv '))) {
          return CommandResult(exitCode: 1, stdout: '', stderr: failWith);
        }
        return _out('');
      },
    );

String _file(String name, {int size = 12}) =>
    '-rw-rw---- 1 u0_a1 media_rw $size 2026-09-07 10:00 $name';
String _dir(String name) =>
    'drwxrwx--- 2 u0_a1 media_rw 4096 2026-09-07 10:00 $name';

/// The device command lines, in order — only the ones that changed something.
List<String> _writes(FakeCommandRunner runner) => runner.requests
    .map((request) => request.arguments.last)
    .where((command) => command.startsWith('cp ') || command.startsWith('mv '))
    .toList();

void main() {
  group('copy within the device', () {
    test('runs one cp on the device and nothing on this computer', () async {
      final runner = _runner({'/sdcard/a.txt': _file('a.txt')});
      final moved = await _driver(
        AdbService(runner: runner, sdk: _sdk()),
      ).copyWithinDevice(from: '/sdcard/a.txt', to: '/sdcard/b.txt');

      expect(_writes(runner), ["cp -p '/sdcard/a.txt' '/sdcard/b.txt'"]);
      expect(moved.devicePath, '/sdcard/b.txt');
      // Nothing touched this computer, and the result does not pretend
      // otherwise by inventing a host path.
      expect(moved.hostPath, isEmpty);
      // No pull and no push: the whole point.
      expect(
        runner.requests
            .map((r) => r.arguments)
            .any((argv) => argv.contains('pull') || argv.contains('push')),
        isFalse,
      );
    });

    test('preserves the timestamp, or every copy is dated now', () async {
      // `cp` without -p re-dates the file, which destroys the one column a
      // file browser is normally sorted by.
      final runner = _runner({'/sdcard/a.txt': _file('a.txt')});
      await _driver(
        AdbService(runner: runner, sdk: _sdk()),
      ).copyWithinDevice(from: '/sdcard/a.txt', to: '/sdcard/b.txt');
      expect(_writes(runner).single, startsWith('cp -p '));
    });

    test('a directory gets -r, and a file does not', () async {
      final runner = _runner({'/sdcard/pics': _dir('pics')});
      await _driver(
        AdbService(runner: runner, sdk: _sdk()),
      ).copyWithinDevice(from: '/sdcard/pics', to: '/sdcard/pics2');
      expect(_writes(runner).single, startsWith('cp -p -r '));
    });

    test('into an existing directory it lands under its own name', () async {
      final runner = _runner({
        '/sdcard/a.txt': _file('a.txt'),
        '/sdcard/Download': _dir('Download'),
      });
      final moved = await _driver(
        AdbService(runner: runner, sdk: _sdk()),
      ).copyWithinDevice(from: '/sdcard/a.txt', to: '/sdcard/Download');
      expect(moved.devicePath, '/sdcard/Download/a.txt');
      // And it says so, rather than leaving the caller to guess where it went.
      expect(moved.note, contains('went in as a.txt'));
      expect(
        _writes(runner).single,
        "cp -p '/sdcard/a.txt' '/sdcard/Download/a.txt'",
      );
    });

    test(
      'a path with a space is quoted, not split into two arguments',
      () async {
        final runner = _runner({'/sdcard/my file.txt': _file('my file.txt')});
        await _driver(AdbService(runner: runner, sdk: _sdk())).copyWithinDevice(
          from: '/sdcard/my file.txt',
          to: '/sdcard/my copy.txt',
        );
        expect(
          _writes(runner).single,
          "cp -p '/sdcard/my file.txt' '/sdcard/my copy.txt'",
        );
      },
    );
  });

  group('move within the device', () {
    test('is one mv — never a copy followed by a delete', () async {
      // Within a filesystem `mv` is a rename and cannot half-finish. A cut that
      // copied and then failed to delete would leave two files, reporting
      // success.
      final runner = _runner({'/sdcard/a.txt': _file('a.txt')});
      await _driver(AdbService(runner: runner, sdk: _sdk())).copyWithinDevice(
        from: '/sdcard/a.txt',
        to: '/sdcard/Download/a.txt',
        move: true,
      );
      expect(_writes(runner), ["mv '/sdcard/a.txt' '/sdcard/Download/a.txt'"]);
      expect(
        runner.requests
            .map((r) => r.arguments.last)
            .any((command) => command.startsWith('rm ')),
        isFalse,
      );
    });

    test('a directory needs no -r, because mv never does', () async {
      final runner = _runner({'/sdcard/pics': _dir('pics')});
      await _driver(
        AdbService(runner: runner, sdk: _sdk()),
      ).copyWithinDevice(from: '/sdcard/pics', to: '/sdcard/pics2', move: true);
      expect(_writes(runner).single, "mv '/sdcard/pics' '/sdcard/pics2'");
    });
  });

  group('the refusals', () {
    test('a destination that exists is refused and nothing runs', () async {
      final runner = _runner({
        '/sdcard/a.txt': _file('a.txt'),
        '/sdcard/b.txt': _file('b.txt', size: 99),
      });
      await expectLater(
        _driver(
          AdbService(runner: runner, sdk: _sdk()),
        ).copyWithinDevice(from: '/sdcard/a.txt', to: '/sdcard/b.txt'),
        throwsA(
          isA<DeviceRefusal>().having(
            (refusal) => refusal.message,
            'message',
            allOf(contains('already exists'), contains('no undo')),
          ),
        ),
      );
      expect(_writes(runner), isEmpty);
    });

    test('overwrite: true replaces it, because it was asked for', () async {
      final runner = _runner({
        '/sdcard/a.txt': _file('a.txt'),
        '/sdcard/b.txt': _file('b.txt'),
      });
      await _driver(AdbService(runner: runner, sdk: _sdk())).copyWithinDevice(
        from: '/sdcard/a.txt',
        to: '/sdcard/b.txt',
        overwrite: true,
      );
      expect(_writes(runner), hasLength(1));
    });

    test('a source that is not there is refused by name', () async {
      final runner = _runner(const {});
      await expectLater(
        _driver(
          AdbService(runner: runner, sdk: _sdk()),
        ).copyWithinDevice(from: '/sdcard/gone.txt', to: '/sdcard/b.txt'),
        throwsA(
          isA<DeviceRefusal>().having(
            (refusal) => refusal.message,
            'message',
            contains('nothing at /sdcard/gone.txt'),
          ),
        ),
      );
      expect(_writes(runner), isEmpty);
    });

    test('a path onto itself is refused rather than run', () async {
      // `mv a a` errors on some shells and no-ops on others. Neither is an
      // answer a file browser should show.
      final runner = _runner({
        '/sdcard/a.txt': _file('a.txt'),
        '/sdcard': _dir('sdcard'),
      });
      await expectLater(
        _driver(AdbService(runner: runner, sdk: _sdk())).copyWithinDevice(
          from: '/sdcard/a.txt',
          to: '/sdcard',
          move: true,
          overwrite: true,
        ),
        throwsA(
          isA<DeviceRefusal>().having(
            (refusal) => refusal.message,
            'message',
            contains('already where you are asking to put it'),
          ),
        ),
      );
      expect(_writes(runner), isEmpty);
    });

    test('a directory into its own subtree is refused, not started', () async {
      // The shell starts this and does not finish it, leaving a half-copied
      // tree behind an error nobody can read.
      final runner = _runner({
        '/sdcard/pics': _dir('pics'),
        '/sdcard/pics/inner': _dir('inner'),
      });
      await expectLater(
        _driver(AdbService(runner: runner, sdk: _sdk())).copyWithinDevice(
          from: '/sdcard/pics',
          to: '/sdcard/pics/inner',
          overwrite: true,
        ),
        throwsA(
          isA<DeviceRefusal>().having(
            (refusal) => refusal.message,
            'message',
            allOf(
              contains('is inside /sdcard/pics'),
              contains('does not terminate'),
            ),
          ),
        ),
      );
      expect(_writes(runner), isEmpty);
    });

    test(
      'a device that complains is a failure, whatever the exit code',
      () async {
        // `cp` says nothing when it works, and `adb shell` forwarded no remote
        // exit code before Android 7 — so any output at all is the failure.
        final runner = _runner({
          '/sdcard/a.txt': _file('a.txt'),
        }, failWith: "cp: '/sdcard/b.txt': Permission denied");
        await expectLater(
          _driver(
            AdbService(runner: runner, sdk: _sdk()),
          ).copyWithinDevice(from: '/sdcard/a.txt', to: '/sdcard/b.txt'),
          throwsA(
            isA<DeviceRefusal>().having(
              (refusal) => refusal.message,
              'message',
              contains('Permission denied'),
            ),
          ),
        );
      },
    );
  });

  group('a device with no file access at all', () {
    test(
      'an iOS driver refuses with the reason, not an empty result',
      () async {
        final driver = SimulatorDeviceDriver(
          simctl: SimctlService(runner: FakeCommandRunner()),
          backend: null,
          target: const SimulatorTarget(
            IosSimulator(
              udid: 'UDID-1',
              name: 'iPhone 17',
              state: SimulatorState.booted,
              runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-26-4',
              deviceTypeIdentifier:
                  'com.apple.CoreSimulator.SimDeviceType.iPhone',
              isAvailable: true,
            ),
          ),
        );
        await expectLater(
          driver.copyWithinDevice(from: '/a', to: '/b'),
          throwsA(
            isA<DeviceRefusal>().having(
              (refusal) => refusal.message,
              'message',
              contains('cannot browse an iOS device'),
            ),
          ),
        );
      },
    );
  });
}
