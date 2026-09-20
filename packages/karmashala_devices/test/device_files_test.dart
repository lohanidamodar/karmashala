import 'dart:convert';

import 'package:test/test.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_devices/src/data/adb_device_driver.dart';
import 'package:karmashala_devices/src/data/adb_service.dart';
import 'package:karmashala_devices/src/data/simctl_service.dart';
import 'package:karmashala_devices/src/data/simulator_device_driver.dart';
import 'package:karmashala_devices/src/domain/android_device.dart';
import 'package:karmashala_devices/src/domain/device_action.dart';
import 'package:karmashala_devices/src/domain/device_driver.dart';
import 'package:karmashala_devices/src/domain/device_target.dart';
import 'package:karmashala_devices/src/domain/ios_simulator.dart';

import './support/fake_command_runner.dart';

const _serial = 'emulator-5554';

AndroidSdk _sdk() => const AndroidSdk(
  root: EnvironmentPath(environmentId: 'windows', path: r'C:\sdk'),
  adb: EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\sdk\platform-tools\adb.exe',
  ),
);

AdbDeviceDriver _driver(AdbService adb, {bool emulator = true}) =>
    AdbDeviceDriver(
      adb: adb,
      target: AndroidTarget(
        AndroidDevice(
          serial: emulator ? _serial : 'F6IZLV6LMFT4U4ZT',
          environmentId: 'windows',
          state: DeviceConnectionState.device,
        ),
      ),
    );

/// A runner that answers by looking at the adb argv, so a test can script one
/// device's whole filesystem without caring what order the service asks in.
FakeCommandRunner _runner(CommandResult Function(List<String> argv) answer) =>
    FakeCommandRunner(responder: (request) => answer(request.arguments));

CommandResult _out(String stdout) =>
    CommandResult(exitCode: 0, stdout: stdout, stderr: '');

/// A listing as a real device sends it: base64, because the service pipes
/// anything containing filenames through it. See `AdbService._readDeviceText`.
CommandResult _lsOut(String listing) =>
    _out(base64.encode(utf8.encode(listing)));

CommandResult _err(String stderr, {int exitCode = 1}) =>
    CommandResult(exitCode: exitCode, stdout: '', stderr: stderr);

/// The whole command adb was told to run on the device, which is one string
/// after `shell` — the thing that fails silently when the quoting is wrong.
String _shellCommand(FakeCommandRunner runner, int index) =>
    runner.requests[index].arguments.last;

void main() {
  group('listing a directory', () {
    test('dereferences the argument with a trailing slash', () async {
      // /sdcard is a symlink on every Android device, and `ls -l /sdcard`
      // prints *the link* — one row. Measured on the owner's handset.
      final runner = _runner(
        (_) => _lsOut(
          'drwxrwx--- 2 root everybody 4096 2024-12-11 18:44 Alarms\n',
        ),
      );
      await AdbService(
        runner: runner,
        sdk: _sdk(),
      ).listDirectory(_serial, '/sdcard');

      expect(_shellCommand(runner, 0), "ls -la '/sdcard/' | base64");
    });

    test(
      'quotes a path with a space so the device shell keeps it whole',
      () async {
        final runner = _runner((_) => _lsOut(''));
        await AdbService(
          runner: runner,
          sdk: _sdk(),
        ).listDirectory(_serial, '/sdcard/karmashala test dir');

        expect(
          _shellCommand(runner, 0),
          "ls -la '/sdcard/karmashala test dir/' | base64",
        );
      },
    );

    test(
      'reports the entries against the directory that was asked for',
      () async {
        final runner = _runner(
          (_) => _lsOut(
            'total 8\n'
            'drwxrwx--- 2 root everybody 4096 2024-12-11 18:44 Camera\n'
            '-rw-rw---- 1 root everybody 17 2026-09-03 18:52 shot.png\n',
          ),
        );
        final listing = await AdbService(
          runner: runner,
          sdk: _sdk(),
        ).listDirectory(_serial, '/sdcard/DCIM');

        expect(listing.path, '/sdcard/DCIM');
        expect(listing.entries.map((e) => e.path), [
          '/sdcard/DCIM/Camera',
          '/sdcard/DCIM/shot.png',
        ]);
      },
    );
  });

  group('names that are not ASCII', () {
    test('survive the trip back, whatever the host console encoding is', () {
      // Measured, not anticipated: CommandRunner decodes with SystemEncoding,
      // which on Windows is the ANSI code page, and a Nepali filename came back
      // as mojibake that cannot be clicked or pulled.
      const name = 'my file नेपाली.txt';
      final runner = _runner(
        (_) =>
            _lsOut('-rw-rw---- 1 u0_a1 media_rw 17 2026-09-03 18:52 $name\n'),
      );

      return expectLater(
        AdbService(runner: runner, sdk: _sdk())
            .listDirectory(_serial, '/sdcard/x')
            .then((l) => l.entries.single.name),
        completion(name),
      );
    });

    test(
      'a device with no base64 still lists, and says the names may be wrong',
      () async {
        // Wrong-and-labelled beats a directory that refuses to open.
        var calls = 0;
        final runner = _runner((argv) {
          calls++;
          if (argv.last.endsWith('| base64')) {
            return _err(
              '/system/bin/sh: base64: inaccessible or not found',
              exitCode: 127,
            );
          }
          return _out('drwxrwx--- 2 root everybody 4096 2024-12-11 18:44 A\n');
        });

        final listing = await AdbService(
          runner: runner,
          sdk: _sdk(),
        ).listDirectory(_serial, '/sdcard');

        expect(calls, 2, reason: 'it should have fallen back, once');
        expect(listing.entries.single.name, 'A');
        expect(listing.note, contains('base64'));
        expect(listing.note, contains('may be spelled wrong'));
      },
    );
  });

  group('a directory that cannot be read', () {
    test(
      'says not permitted, and never comes back as an empty folder',
      () async {
        // The failure this whole surface exists to prevent: an empty listing and
        // a refusal are indistinguishable in a file browser.
        final runner = _runner((_) => _err('ls: /data: Permission denied'));
        final service = AdbService(runner: runner, sdk: _sdk());

        await expectLater(
          service.listDirectory(_serial, '/data'),
          throwsA(
            isA<DeviceRefusal>().having(
              (e) => e.message,
              'message',
              allOf(contains('/data'), contains('not readable')),
            ),
          ),
        );
      },
    );

    test(
      'an app\'s own directory is refused with what would reach it',
      () async {
        // Either support run-as and say when it is unavailable, or leave it out
        // and say so. This build leaves it out, and this is the saying so.
        final runner = _runner(
          (_) => _err('ls: /data/data/com.example/: Permission denied'),
        );

        await expectLater(
          AdbService(
            runner: runner,
            sdk: _sdk(),
          ).listDirectory(_serial, '/data/data/com.example'),
          throwsA(
            isA<DeviceRefusal>().having(
              (e) => e.message,
              'message',
              allOf(contains('run-as'), contains('debuggable')),
            ),
          ),
        );
      },
    );

    test('a device that swallows the exit code is still believed', () async {
      // adb shell did not forward the remote exit code before Android 7, so
      // deciding on the status alone reports a refusal as an empty folder.
      final runner = _runner(
        (_) => const CommandResult(
          exitCode: 0,
          stdout: 'ls: /data: Permission denied',
          stderr: '',
        ),
      );

      await expectLater(
        AdbService(runner: runner, sdk: _sdk()).listDirectory(_serial, '/data'),
        throwsA(isA<DeviceRefusal>()),
      );
    });

    test('a missing path says so rather than blaming permissions', () async {
      final runner = _runner(
        (_) => _err('ls: /sdcard/nope/: No such file or directory'),
      );

      await expectLater(
        AdbService(
          runner: runner,
          sdk: _sdk(),
        ).listDirectory(_serial, '/sdcard/nope'),
        throwsA(
          isA<DeviceRefusal>().having(
            (e) => e.message,
            'message',
            contains('nothing at /sdcard/nope'),
          ),
        ),
      );
    });
  });

  group('stat', () {
    test('asks for the entry itself, not a directory\'s contents', () async {
      final runner = _runner(
        (_) => _lsOut(
          '-rw-rw---- 1 root everybody 17 2026-09-03 18:52 /sdcard/a.txt\n',
        ),
      );
      final entry = await AdbService(
        runner: runner,
        sdk: _sdk(),
      ).statPath(_serial, '/sdcard/a.txt');

      expect(_shellCommand(runner, 0), "ls -lad '/sdcard/a.txt' | base64");
      // The device echoes the argument as the name; only the last segment is
      // about this entry.
      expect(entry!.name, 'a.txt');
      expect(entry.path, '/sdcard/a.txt');
      expect(entry.sizeBytes, 17);
    });

    test(
      'absent is null, which is a different answer from unreadable',
      () async {
        // Null makes a push safe; a throw makes it hopeless. Collapsing them
        // would make one of the two decisions wrong.
        final runner = _runner(
          (_) => _err('ls: /sdcard/nope: No such file or directory'),
        );
        expect(
          await AdbService(
            runner: runner,
            sdk: _sdk(),
          ).statPath(_serial, '/sdcard/nope'),
          isNull,
        );
      },
    );

    test('unreadable throws', () async {
      final runner = _runner((_) => _err('ls: /data/x: Permission denied'));
      await expectLater(
        AdbService(runner: runner, sdk: _sdk()).statPath(_serial, '/data/x'),
        throwsA(isA<DeviceRefusal>()),
      );
    });
  });

  group('pulling a file off the device', () {
    test('believes the summary line adb prints on stderr', () async {
      // Measured against a real device: adb pull reports success on **stderr**
      // with exit code 0, so reading only stdout concludes nothing moved.
      final runner = _runner(
        (_) => const CommandResult(
          exitCode: 0,
          stdout: '',
          stderr:
              '/sdcard/.dev: 1 file pulled, 0 skipped. 0.0 MB/s '
              '(16 bytes in 0.006s)',
        ),
      );
      final moved = await AdbService(runner: runner, sdk: _sdk()).pullFile(
        _serial,
        devicePath: '/sdcard/.dev',
        hostPath: r'C:\tmp\dev.txt',
      );

      expect(moved.bytes, 16);
      expect(moved.hostPath, r'C:\tmp\dev.txt');
    });

    test('hands the path to adb unquoted, because no shell sees it', () async {
      // `adb pull` uses the sync service, not a shell. Quoting here would put
      // the quotes into the filename.
      final runner = _runner(
        (_) => _err('1 file pulled, 0 skipped. (1 bytes in 0.0s)', exitCode: 0),
      );
      await AdbService(runner: runner, sdk: _sdk()).pullFile(
        _serial,
        devicePath: '/sdcard/my file.txt',
        hostPath: r'C:\tmp\my file.txt',
      );

      expect(runner.requests.single.arguments, [
        '-s',
        _serial,
        'pull',
        '/sdcard/my file.txt',
        r'C:\tmp\my file.txt',
      ]);
    });

    test(
      'a failure is a refusal quoting adb, not a silent empty file',
      () async {
        final runner = _runner(
          (_) => _err("adb: error: remote object '/data/x' does not exist"),
        );

        await expectLater(
          AdbService(
            runner: runner,
            sdk: _sdk(),
          ).pullFile(_serial, devicePath: '/data/x', hostPath: r'C:\tmp\x'),
          throwsA(
            isA<DeviceRefusal>().having(
              (e) => e.message,
              'message',
              contains('does not exist'),
            ),
          ),
        );
      },
    );

    test('a failed pull takes its partial file away', () async {
      // adb writes the destination as it goes, so a refused pull would leave a
      // truncated file looking like the real one.
      final removed = <String>[];
      final service = AdbService(
        runner: _runner((_) => _err('adb: error: failed to copy')),
        sdk: _sdk(),
        hostFileExists: (_) async => false,
        removeHostFile: (path) async => removed.add(path),
      );

      await expectLater(
        service.pullFile(_serial, devicePath: '/data/x', hostPath: r'C:\tmp\x'),
        throwsA(isA<DeviceRefusal>()),
      );
      expect(removed, [r'C:\tmp\x']);
    });

    test('a failed pull leaves a file that was already there alone', () async {
      final removed = <String>[];
      final service = AdbService(
        runner: _runner((_) => _err('adb: error: failed to copy')),
        sdk: _sdk(),
        hostFileExists: (_) async => true,
        removeHostFile: (path) async => removed.add(path),
      );

      await expectLater(
        service.pullFile(_serial, devicePath: '/data/x', hostPath: r'C:\tmp\x'),
        throwsA(isA<DeviceRefusal>()),
      );
      expect(removed, isEmpty);
    });

    test('an adb that cannot run also takes the partial file away', () async {
      final removed = <String>[];
      final runner = FakeCommandRunner(
        throwError: CommandException('adb.exe is not there'),
      );
      final service = AdbService(
        runner: runner,
        sdk: _sdk(),
        hostFileExists: (_) async => false,
        removeHostFile: (path) async => removed.add(path),
      );

      await expectLater(
        service.pullFile(_serial, devicePath: '/data/x', hostPath: r'C:\tmp\x'),
        throwsA(isA<CommandException>()),
      );
      expect(removed, [r'C:\tmp\x']);
    });

    test(
      'is reported to whoever is recording what happens to devices',
      () async {
        final runner = _runner(
          (_) =>
              _err('1 file pulled, 0 skipped. (16 bytes in 0.0s)', exitCode: 0),
        );
        final actions = <DeviceAction>[];
        final service = AdbService(runner: runner, sdk: _sdk())
          ..actionSink = actions.add;
        await service.pullFile(
          _serial,
          devicePath: '/sdcard/a',
          hostPath: r'C:\a',
        );

        expect(actions.single.verb, 'pullFile');
        expect(actions.single.ok, isTrue);
      },
    );
  });

  group('pushing a file onto the device', () {
    test('refuses to overwrite unless asked, and copies nothing', () async {
      // There is no undo on the other side of the wire.
      final runner = _runner((argv) {
        if (argv.contains('shell')) {
          return _lsOut(
            '-rw-rw---- 1 root everybody 17 2026-09-03 18:52 '
            '/sdcard/a.txt\n',
          );
        }
        return _err('should never get here');
      });
      final driver = _driver(AdbService(runner: runner, sdk: _sdk()));

      await expectLater(
        driver.pushFile(hostPath: r'C:\a.txt', devicePath: '/sdcard/a.txt'),
        throwsA(
          isA<DeviceRefusal>().having(
            (e) => e.message,
            'message',
            allOf(contains('already exists'), contains('Nothing was copied')),
          ),
        ),
      );
      expect(
        runner.requests.any((r) => r.arguments.contains('push')),
        isFalse,
        reason: 'a refused push must not have run',
      );
    });

    test('overwrites when it is asked to', () async {
      final runner = _runner((argv) {
        if (argv.contains('shell')) {
          return _lsOut(
            '-rw-rw---- 1 root everybody 17 2026-09-03 18:52 /sdcard/a.txt\n',
          );
        }
        return _err(
          '1 file pushed, 0 skipped. (17 bytes in 0.0s)',
          exitCode: 0,
        );
      });
      final driver = _driver(AdbService(runner: runner, sdk: _sdk()));

      final moved = await driver.pushFile(
        hostPath: r'C:\a.txt',
        devicePath: '/sdcard/a.txt',
        overwrite: true,
      );
      expect(moved.bytes, 17);
    });

    test('a directory destination says where the file actually went', () async {
      // `adb push file dir` already does this; doing it here as well is what
      // lets the overwrite check see the real destination.
      var stats = 0;
      final runner = _runner((argv) {
        if (argv.contains('shell')) {
          stats++;
          // First: the destination directory. Second: nothing inside it yet.
          return stats == 1
              ? _lsOut(
                  'drwxrwx--- 2 root everybody 4096 2024-12-11 18:44 '
                  '/sdcard/Download\n',
                )
              : _err('ls: no such file: No such file or directory');
        }
        return _err('1 file pushed, 0 skipped. (5 bytes in 0.0s)', exitCode: 0);
      });
      final driver = _driver(AdbService(runner: runner, sdk: _sdk()));

      final moved = await driver.pushFile(
        hostPath: r'C:\Users\me\notes final.txt',
        devicePath: '/sdcard/Download',
      );

      expect(moved.devicePath, '/sdcard/Download/notes final.txt');
      expect(moved.note, contains('notes final.txt'));
    });

    test('a Windows host path gives up its own basename correctly', () async {
      // The file came out of a Windows dialog, so the separator is a backslash
      // and package:path on a Linux CI would return the whole string.
      var stats = 0;
      final runner = _runner((argv) {
        if (argv.contains('shell')) {
          stats++;
          return stats == 1
              ? _lsOut('drwxrwx--- 2 root everybody 4096 2024-12-11 18:44 /x\n')
              : _err('ls: nope: No such file or directory');
        }
        return _err('1 file pushed, 0 skipped. (5 bytes in 0.0s)', exitCode: 0);
      });
      final driver = _driver(AdbService(runner: runner, sdk: _sdk()));

      final moved = await driver.pushFile(
        hostPath: r'C:\Users\dlohani\Desktop\build.apk',
        devicePath: '/x',
      );
      expect(moved.devicePath, '/x/build.apk');
    });
  });

  group('deleting', () {
    test('refuses a directory unless recursion is asked for', () async {
      final runner = _runner(
        (_) => _lsOut(
          'drwxrwx--- 2 root everybody 4096 2024-12-11 18:44 /sdcard/DCIM\n',
        ),
      );
      final driver = _driver(AdbService(runner: runner, sdk: _sdk()));

      await expectLater(
        driver.deletePath('/sdcard/DCIM'),
        throwsA(
          isA<DeviceRefusal>().having(
            (e) => e.message,
            'message',
            allOf(contains('everything inside it'), contains('no undo')),
          ),
        ),
      );
      expect(
        runner.requests.any((r) => r.arguments.last.startsWith('rm')),
        isFalse,
      );
    });

    test('a path that is not there is an error, not a quiet success', () async {
      // "Deleted" for a path that was never found tells someone their file is
      // gone when it is somewhere else.
      final runner = _runner(
        (_) => _err('ls: /sdcard/gone: No such file or directory'),
      );
      final driver = _driver(AdbService(runner: runner, sdk: _sdk()));

      await expectLater(
        driver.deletePath('/sdcard/gone'),
        throwsA(isA<DeviceRefusal>()),
      );
    });

    test('quotes the path, and passes -r only when recursive', () async {
      final runner = _runner((argv) {
        if (argv.last.startsWith('ls')) {
          return _lsOut(
            'drwxrwx--- 2 root everybody 4096 2024-12-11 18:44 /sdcard/x y\n',
          );
        }
        return _out('');
      });
      final driver = _driver(AdbService(runner: runner, sdk: _sdk()));

      await driver.deletePath('/sdcard/x y', recursive: true);
      expect(_shellCommand(runner, 1), "rm -r '/sdcard/x y'");
    });

    test('rm speaking at all is a failure, whatever the exit code', () async {
      // `rm` is silent when it works, and a pre-Android-7 device does not
      // forward the exit code.
      final runner = _runner((argv) {
        if (argv.last.startsWith('ls')) {
          return _lsOut(
            '-rw-rw---- 1 root everybody 1 2026-09-03 18:52 '
            '/system/build.prop\n',
          );
        }
        return const CommandResult(
          exitCode: 0,
          stdout: 'rm: /system/build.prop: Read-only file system',
          stderr: '',
        );
      });
      final driver = _driver(AdbService(runner: runner, sdk: _sdk()));

      await expectLater(
        driver.deletePath('/system/build.prop'),
        throwsA(
          isA<DeviceRefusal>().having(
            (e) => e.message,
            'message',
            contains('Read-only file system'),
          ),
        ),
      );
    });
  });

  group('what the Android driver says it can do', () {
    test('declares file access, on a handset as much as an emulator', () {
      final adb = AdbService(runner: FakeCommandRunner(), sdk: _sdk());
      expect(_driver(adb, emulator: false).can(DeviceCapability.files), isTrue);
      expect(
        _driver(adb, emulator: false).missingReason(DeviceCapability.files),
        isNull,
      );
    });

    test(
      'offers roots rather than pretending there is one filesystem',
      () async {
        final adb = AdbService(runner: FakeCommandRunner(), sdk: _sdk());
        final roots = await _driver(adb).fileRoots();

        expect(roots.map((r) => r.path), ['/sdcard', '/data/local/tmp', '/']);
        // The read-only one is labelled read-only rather than failing later.
        expect(roots.last.writable, isFalse);
        expect(roots.first.writable, isTrue);
        // Every root explains what will be refused there, because that is the
        // part a person cannot see from the path.
        expect(roots.every((r) => r.description.isNotEmpty), isTrue);
      },
    );

    test(
      'a pull of a directory is refused by name, not silently expanded',
      () async {
        final runner = _runner(
          (_) => _lsOut(
            'drwxrwx--- 2 root everybody 4096 2024-12-11 18:44 /sdcard/DCIM\n',
          ),
        );
        final driver = _driver(AdbService(runner: runner, sdk: _sdk()));

        await expectLater(
          driver.pullFile(devicePath: '/sdcard/DCIM', hostPath: r'C:\x'),
          throwsA(
            isA<DeviceRefusal>().having(
              (e) => e.message,
              'message',
              contains('one file at a time'),
            ),
          ),
        );
      },
    );
  });

  group('what the iOS driver says it cannot do', () {
    SimulatorDeviceDriver simulator() => SimulatorDeviceDriver(
      simctl: SimctlService(runner: FakeCommandRunner()),
      backend: null,
      target: const SimulatorTarget(
        IosSimulator(
          udid: 'UDID-1',
          name: 'iPhone 17',
          state: SimulatorState.booted,
          runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-26-4',
          deviceTypeIdentifier: 'com.apple.CoreSimulator.SimDeviceType.iPhone',
          isAvailable: true,
        ),
      ),
    );

    test('does not claim file access', () {
      expect(simulator().can(DeviceCapability.files), isFalse);
    });

    test('gives a reason that is about iOS, not about WebDriverAgent', () {
      // Fetching WDA would not give this app a usbmuxd client, so the WDA
      // sentence here would send someone after a capability it cannot supply.
      final reason = simulator().missingReason(DeviceCapability.files)!;
      expect(reason, contains('usbmuxd'));
      expect(reason, isNot(contains('fetch_wda')));
      // And it says what a later implementation would do, so the next person
      // is not guessing.
      expect(reason, contains('Simulator'));
      // And what still works, so nobody concludes iOS is a dead end.
      expect(reason, contains('screenshots'));
    });

    test('every file verb refuses rather than answering emptily', () async {
      // An empty root list and an empty directory both read as "this device has
      // no files on it", which is a confident false statement.
      final driver = simulator();
      for (final call in <Future<Object?> Function()>[
        driver.fileRoots,
        () => driver.listDirectory('/'),
        () => driver.stat('/'),
        () => driver.pullFile(devicePath: '/a', hostPath: '/b'),
        () => driver.pushFile(hostPath: '/a', devicePath: '/b'),
        () => driver.deletePath('/a'),
      ]) {
        await expectLater(call(), throwsA(isA<DeviceRefusal>()));
      }
    });
  });
}
