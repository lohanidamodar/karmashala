import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import 'package:karmashala_devices/src/data/adb_service.dart';
import 'package:karmashala_devices/src/data/uiautomator_parsing.dart';
import 'package:karmashala_devices/src/domain/android_device.dart';
import 'package:karmashala_devices/src/domain/device_input.dart';
import 'package:karmashala_devices/src/domain/logcat_entry.dart';
import 'package:test/test.dart';

import './support/fake_command_runner.dart';

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
  _installSpaceTests();

  group('encodeInputText', () {
    test('encodes spaces as %s, which is what Android input expects', () {
      expect(encodeInputText('hello world'), 'hello%sworld');
    });

    test(
      'escapes shell metacharacters that would otherwise be interpreted',
      () {
        expect(encodeInputText(r'a&b'), r'a\&b');
        expect(encodeInputText('a"b'), r'a\"b');
        expect(encodeInputText(r"it's"), r"it\'s");
        expect(encodeInputText(r'$HOME'), r'\$HOME');
      },
    );

    test('leaves ordinary text untouched', () {
      expect(encodeInputText('flutter123'), 'flutter123');
    });
  });

  group('listDevices', () {
    test(
      'asks adb for the long listing and binds results to the environment',
      () async {
        final runner = FakeCommandRunner(
          responder: (_) => const CommandResult(
            exitCode: 0,
            stdout:
                'List of devices attached\n'
                'emulator-5554  device product:sdk model:Pixel transport_id:7\n',
            stderr: '',
          ),
        );
        final devices = await AdbService(
          runner: runner,
          sdk: _sdk(),
        ).listDevices();

        expect(runner.requests.single.executable, _adbPath);
        expect(_argv(runner, 0), ['devices', '-l']);
        expect(devices.single.serial, 'emulator-5554');
        expect(devices.single.environmentId, 'windows');
      },
    );

    test('returns empty rather than throwing when adb fails', () async {
      final runner = FakeCommandRunner(
        responder: (_) =>
            const CommandResult(exitCode: 1, stdout: '', stderr: 'no devices'),
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
      expect(_argv(runner, 0), [
        '-s',
        'S1',
        'shell',
        'input',
        'tap',
        '100',
        '250',
      ]);
    });

    test('swipe passes the duration in milliseconds', () async {
      final runner = FakeCommandRunner();
      await AdbService(runner: runner, sdk: _sdk()).swipe(
        'S1',
        fromX: 1,
        fromY: 2,
        toX: 3,
        toY: 4,
        duration: const Duration(milliseconds: 350),
      );
      expect(_argv(runner, 0), [
        '-s',
        'S1',
        'shell',
        'input',
        'swipe',
        '1',
        '2',
        '3',
        '4',
        '350',
      ]);
    });

    test('pressKey maps the enum to an Android keycode', () async {
      final runner = FakeCommandRunner();
      await AdbService(
        runner: runner,
        sdk: _sdk(),
      ).pressKey('S1', DeviceKey.recents);
      expect(_argv(runner, 0), [
        '-s',
        'S1',
        'shell',
        'input',
        'keyevent',
        'KEYCODE_APP_SWITCH',
      ]);
    });

    test('inputText encodes before sending', () async {
      final runner = FakeCommandRunner();
      await AdbService(runner: runner, sdk: _sdk()).inputText('S1', 'hi there');
      expect(_argv(runner, 0), [
        '-s',
        'S1',
        'shell',
        'input',
        'text',
        'hi%sthere',
      ]);
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
        '-s',
        'S1',
        'shell',
        'screencap',
        '-p',
        '/data/local/tmp/karmashala_screen.png',
      ]);
      expect(_argv(runner, 1), [
        '-s',
        'S1',
        'pull',
        '/data/local/tmp/karmashala_screen.png',
        r'C:\tmp\shot.png',
      ]);
      expect(_argv(runner, 2).sublist(2), [
        'shell',
        'rm',
        '-f',
        '/data/local/tmp/karmashala_screen.png',
      ]);
      expect(bytes, [0x89, 0x50]);
    });

    test('reports a failed capture', () async {
      final runner = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'permission denied',
        ),
      );
      expect(
        () => AdbService(
          runner: runner,
          sdk: _sdk(),
        ).screenshot('S1', hostPath: 'x.png'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('appearance', () {
    test('flips the ui mode through the service the tile uses', () async {
      // `cmd uimode night`, not `settings put secure ui_night_mode`: the
      // setting alone does not repaint the running system UI.
      final runner = FakeCommandRunner();
      await AdbService(
        runner: runner,
        sdk: _sdk(),
      ).setNightMode('S1', dark: true);

      expect(_argv(runner, 0), [
        '-s',
        'S1',
        'shell',
        'cmd',
        'uimode',
        'night',
        'yes',
      ]);
    });

    test('light is "no", which is the other word the command takes', () async {
      final runner = FakeCommandRunner();
      await AdbService(
        runner: runner,
        sdk: _sdk(),
      ).setNightMode('S1', dark: false);

      expect(_argv(runner, 0).last, 'no');
    });

    test('reads the device rather than trusting the last write', () async {
      // The Quick Settings tile and a dusk schedule both move this behind the
      // pane's back, so a remembered flag would offer "dark" on a dark device.
      final runner = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 0,
          stdout: 'Night mode: yes\n',
          stderr: '',
        ),
      );

      expect(
        await AdbService(runner: runner, sdk: _sdk()).isNightMode('S1'),
        isTrue,
      );
      expect(_argv(runner, 0), ['-s', 'S1', 'shell', 'cmd', 'uimode', 'night']);
    });

    test('a device that will not answer says so instead of guessing', () async {
      final runner = FakeCommandRunner(
        responder: (_) =>
            const CommandResult(exitCode: 1, stdout: '', stderr: 'no such cmd'),
      );

      expect(
        await AdbService(runner: runner, sdk: _sdk()).isNightMode('S1'),
        isNull,
      );
    });

    test('a refused write is thrown, not swallowed', () async {
      final runner = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 255,
          stdout: '',
          stderr: "Error: mode must be 'yes', 'no', or 'auto'",
        ),
      );

      expect(
        () => AdbService(
          runner: runner,
          sdk: _sdk(),
        ).setNightMode('S1', dark: true),
        throwsStateError,
      );
    });
  });

  group('openUrl', () {
    test('sends a VIEW intent with the url as data', () async {
      final runner = FakeCommandRunner();
      await AdbService(
        runner: runner,
        sdk: _sdk(),
      ).openUrl('S1', 'myapp://deep/link');

      expect(_argv(runner, 0), [
        '-s',
        'S1',
        'shell',
        'am',
        'start',
        '-a',
        'android.intent.action.VIEW',
        '-d',
        'myapp://deep/link',
      ]);
    });

    test(
      'a link nothing can handle is a failure, exit code notwithstanding',
      () async {
        // Measured against an API 34 emulator: `am start` exits **0** when the
        // intent resolves to nothing and complains on stderr instead.
        final runner = FakeCommandRunner(
          responder: (_) => const CommandResult(
            exitCode: 0,
            stdout: 'Starting: Intent { act=android.intent.action.VIEW }\n',
            stderr:
                'Error: Activity not started, unable to resolve Intent '
                '{ act=android.intent.action.VIEW dat=nosuchapp://x }\n',
          ),
        );

        expect(
          () => AdbService(
            runner: runner,
            sdk: _sdk(),
          ).openUrl('S1', 'nosuchapp://x'),
          throwsStateError,
        );
      },
    );

    test('an ordinary start is not treated as a failure', () async {
      // `am start` narrates every launch on stdout; only the stderr complaint
      // means anything went wrong.
      final runner = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 0,
          stdout: 'Starting: Intent { dat=https://example.com/... }\n',
          stderr: '',
        ),
      );

      await AdbService(
        runner: runner,
        sdk: _sdk(),
      ).openUrl('S1', 'https://example.com');
    });
  });

  group('logcat', () {
    test('filters to the package pids', () async {
      final runner = FakeCommandRunner(
        responder: (request) {
          if (request.arguments.contains('pidof')) {
            return const CommandResult(
              exitCode: 0,
              stdout: '1234 5678',
              stderr: '',
            );
          }
          return const CommandResult(
            exitCode: 0,
            stdout:
                '08-29 20:15:33.123  1234  5678 I MyTag   : hello\n'
                '08-29 20:15:34.000  1234  5678 D Other   : noise\n',
            stderr: '',
          );
        },
      );
      final entries = await AdbService(
        runner: runner,
        sdk: _sdk(),
      ).readLogcat('S1', packageName: 'com.example.app');

      expect(_argv(runner, 0).sublist(2), [
        'shell',
        'pidof',
        'com.example.app',
      ]);
      expect(
        _argv(runner, 1),
        containsAllInOrder(['shell', 'logcat', '-d', '-v', 'threadtime']),
      );
      expect(_argv(runner, 1), containsAllInOrder(['--pid', '1234']));
      expect(entries, hasLength(2));
      expect(entries.first.tag, 'MyTag');
    });

    test(
      'returns empty when the package is not running, not the whole log',
      () async {
        final runner = FakeCommandRunner(
          responder: (request) => request.arguments.contains('pidof')
              ? const CommandResult(exitCode: 1, stdout: '', stderr: '')
              : const CommandResult(
                  exitCode: 0,
                  stdout: 'lots of noise',
                  stderr: '',
                ),
        );
        final entries = await AdbService(
          runner: runner,
          sdk: _sdk(),
        ).readLogcat('S1', packageName: 'com.absent.app');
        expect(entries, isEmpty);
        expect(
          runner.requests,
          hasLength(1),
          reason: 'must not run logcat at all',
        );
      },
    );

    test('applies the minimum level filter', () async {
      final runner = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 0,
          stdout:
              '08-29 20:15:33.123  1  2 V A: verbose\n'
              '08-29 20:15:33.124  1  2 E B: error\n',
          stderr: '',
        ),
      );
      final entries = await AdbService(
        runner: runner,
        sdk: _sdk(),
      ).readLogcat('S1', minLevel: LogLevel.error);
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
              exitCode: 0,
              stdout: 'Pixel_8_Pro\nsambandha_test\n',
              stderr: '',
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
            exitCode: 0,
            stdout: 'sambandha_test\nOK\n',
            stderr: '',
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
      final avds = await AdbService(
        runner: runner,
        sdk: _sdk(withEmulator: false),
      ).listAvds();
      expect(avds, isEmpty);
      expect(runner.requests, isEmpty);
    });

    test('booting without an emulator package explains why', () async {
      expect(
        () => AdbService(
          runner: FakeCommandRunner(),
          sdk: _sdk(withEmulator: false),
        ).bootAvd('X'),
        throwsA(isA<StateError>()),
      );
    });

    test('boots an AVD as a long-lived process, headless by default', () async {
      // The pane's live view is the screen; a second floating emulator window
      // is in the way. `-no-window` is what makes that possible.
      final runner = FakeCommandRunner();
      await AdbService(runner: runner, sdk: _sdk()).bootAvd('Pixel_8_Pro');
      expect(runner.startRequests.single.executable, _emulatorPath);
      expect(runner.startRequests.single.arguments, [
        '-avd',
        'Pixel_8_Pro',
        '-no-window',
        '-no-boot-anim',
      ]);
    });

    test('boots with a window when asked, for the extended controls', () async {
      final runner = FakeCommandRunner();
      await AdbService(
        runner: runner,
        sdk: _sdk(),
      ).bootAvd('Pixel_8_Pro', headless: false);
      expect(runner.startRequests.single.arguments, [
        '-avd',
        'Pixel_8_Pro',
        '-no-boot-anim',
      ]);
    });

    test('appends the slimming flags after our own', () async {
      // The argv is the caller's policy: `AdbService` knows nothing about what
      // these mean.
      final runner = FakeCommandRunner();
      await AdbService(runner: runner, sdk: _sdk()).bootAvd(
        'Pixel_8_Pro',
        extraArguments: const ['-no-audio', '-gpu', 'host'],
      );
      expect(runner.startRequests.single.arguments, [
        '-avd',
        'Pixel_8_Pro',
        '-no-window',
        '-no-boot-anim',
        '-no-audio',
        '-gpu',
        'host',
      ]);
    });

    test(
      'drains the emulator output, which is what stops a boot wedging',
      () async {
        // The emulator's stdout is a pipe of a few kilobytes; with no reader it
        // fills, the boot stops part-way, and it looks like a slow emulator.
        final handle = FakeProcessHandle();
        final runner = FakeCommandRunner(processFactory: (_) => handle);
        final lines = <String>[];
        await AdbService(
          runner: runner,
          sdk: _sdk(),
        ).bootAvd('Pixel_8_Pro', onLog: lines.add);
        handle.emitStdout('INFO | Boot completed in 12345 ms');
        handle.emitStderr('WARNING | Netsim is gone');
        await Future<void>.delayed(Duration.zero);
        expect(lines, [
          'INFO | Boot completed in 12345 ms',
          'WARNING | Netsim is gone',
        ]);
      },
    );

    test('matches a booting emulator to its AVD by asking it, not by '
        'diffing the device list', () async {
      // Two emulators starting together make a before/after diff ambiguous,
      // and a diff cannot recognise an AVD that was already running.
      final runner = FakeCommandRunner(
        responder: (request) => switch (request.arguments.join(' ')) {
          'devices -l' => const CommandResult(
            exitCode: 0,
            stdout:
                'List of devices attached\n'
                'emulator-5554  device product:sdk model:A transport_id:1\n'
                'emulator-5556  device product:sdk model:B transport_id:2\n',
            stderr: '',
          ),
          '-s emulator-5554 emu avd name' => const CommandResult(
            exitCode: 0,
            stdout: 'Other_Avd\nOK\n',
            stderr: '',
          ),
          '-s emulator-5556 emu avd name' => const CommandResult(
            exitCode: 0,
            stdout: 'Pixel_8_Pro\nOK\n',
            stderr: '',
          ),
          _ => const CommandResult(exitCode: 0, stdout: '', stderr: ''),
        },
      );
      final adb = AdbService(runner: runner, sdk: _sdk());
      expect(await adb.serialForAvd('Pixel_8_Pro'), 'emulator-5556');
      expect(await adb.serialForAvd('Nothing_Like_This'), isNull);
    });

    test('boot completion is sys.boot_completed, not "adb answered"', () async {
      // A device answers adb well before Android has booted. Headless there is
      // nothing on screen to tell them apart.
      final runner = FakeCommandRunner(
        responder: (request) => CommandResult(
          exitCode: 0,
          stdout: request.arguments.contains('sys.boot_completed') ? '1\n' : '',
          stderr: '',
        ),
      );
      final adb = AdbService(runner: runner, sdk: _sdk());
      expect(await adb.isBootCompleted('emulator-5554'), isTrue);
      expect(_argv(runner, 0), [
        '-s',
        'emulator-5554',
        'shell',
        'getprop',
        'sys.boot_completed',
      ]);
    });

    test('a hardware serial is ro.serialno, else ro.boot.serialno', () async {
      final runner = FakeCommandRunner(
        responder: (request) => CommandResult(
          exitCode: 0,
          stdout: switch (request.arguments.last) {
            'ro.boot.serialno' => 'QX7TESTSERIAL01\n',
            _ => '\n',
          },
          stderr: '',
        ),
      );
      final adb = AdbService(runner: runner, sdk: _sdk());
      expect(await adb.hardwareSerial('192.168.1.20:5555'), 'QX7TESTSERIAL01');
      expect(_argv(runner, 0), [
        '-s',
        '192.168.1.20:5555',
        'shell',
        'getprop',
        'ro.serialno',
      ]);
    });

    test('an answer that is not one token is no hardware serial', () async {
      final runner = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 0,
          stdout: '/system/bin/sh: getprop: inaccessible or not found\n',
          stderr: '',
        ),
      );
      expect(
        await AdbService(
          runner: runner,
          sdk: _sdk(),
        ).hardwareSerial('192.168.1.20:5555'),
        isNull,
      );
    });

    test('a device that answers adb but has not booted is not ready', () async {
      final runner = FakeCommandRunner(
        responder: (_) =>
            const CommandResult(exitCode: 0, stdout: '\n', stderr: ''),
      );
      expect(
        await AdbService(
          runner: runner,
          sdk: _sdk(),
        ).isBootCompleted('emulator-5554'),
        isFalse,
      );
    });

    test(
      'bootAvdAndWait returns the serial once it has really booted',
      () async {
        var booted = false;
        final runner = FakeCommandRunner(
          responder: (request) {
            final args = request.arguments.join(' ');
            if (args == 'devices -l') {
              return const CommandResult(
                exitCode: 0,
                stdout:
                    'List of devices attached\n'
                    'emulator-5556  device product:sdk model:B transport_id:2\n',
                stderr: '',
              );
            }
            if (args.endsWith('emu avd name')) {
              return const CommandResult(
                exitCode: 0,
                stdout: 'Pixel_8_Pro\nOK\n',
                stderr: '',
              );
            }
            if (args.contains('sys.boot_completed')) {
              final answer = booted ? '1\n' : '0\n';
              booted = true;
              return CommandResult(exitCode: 0, stdout: answer, stderr: '');
            }
            return const CommandResult(exitCode: 0, stdout: '', stderr: '');
          },
        );
        final serial = await AdbService(runner: runner, sdk: _sdk())
            .bootAvdAndWait(
              'Pixel_8_Pro',
              pollInterval: Duration.zero,
              timeout: const Duration(seconds: 5),
            );
        expect(serial, 'emulator-5556');
        expect(runner.startRequests.single.arguments, contains('-no-window'));
      },
    );

    test(
      'an emulator that never boots fails instead of spinning forever',
      () async {
        final runner = FakeCommandRunner(
          responder: (_) => const CommandResult(
            exitCode: 0,
            stdout: 'List of devices attached\n',
            stderr: '',
          ),
        );
        await expectLater(
          AdbService(runner: runner, sdk: _sdk()).bootAvdAndWait(
            'Pixel_8_Pro',
            pollInterval: Duration.zero,
            timeout: const Duration(milliseconds: 20),
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('did not become reachable'),
            ),
          ),
        );
      },
    );
  });

  group('screenSize', () {
    test('reads the device coordinate space', () async {
      final runner = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 0,
          stdout: 'Physical size: 1080x2400',
          stderr: '',
        ),
      );
      final size = await AdbService(
        runner: runner,
        sdk: _sdk(),
      ).screenSize('S1');
      expect(size, const DeviceScreenSize(width: 1080, height: 2400));
    });
  });

  group('dumpUiHierarchy', () {
    // uiautomator's own reply on success. The typo is upstream's.
    const dumped =
        'UI hierchary dumped to: '
        '/data/local/tmp/karmashala_ui_dump.xml';
    const xml =
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<hierarchy rotation="0">'
        '<node index="0" text="Sign in" class="android.widget.Button" '
        'package="com.example" content-desc="" clickable="true" enabled="true" '
        'bounds="[100,200][300,400]" />'
        '</hierarchy>';

    /// Answers the dump/cat/rm sequence, with [dumpOutput] scripted per attempt.
    FakeCommandRunner runnerFor(List<String> dumpOutputs, {String body = xml}) {
      var dumps = 0;
      return FakeCommandRunner(
        responder: (request) {
          final args = request.arguments;
          if (args.contains('uiautomator')) {
            final index = dumps < dumpOutputs.length
                ? dumps
                : dumpOutputs.length - 1;
            dumps++;
            return CommandResult(
              exitCode: 0,
              stdout: dumpOutputs[index],
              stderr: '',
            );
          }
          if (args.contains('cat')) {
            return CommandResult(exitCode: 0, stdout: body, stderr: '');
          }
          return const CommandResult(exitCode: 0, stdout: '', stderr: '');
        },
      );
    }

    AdbService service(FakeCommandRunner runner) => AdbService(
      runner: runner,
      sdk: _sdk(),
      uiDumpRetryDelay: Duration.zero,
    );

    test('dumps to a device file and reads it back with cat', () async {
      final runner = runnerFor([dumped]);
      final tree = await service(runner).dumpUiHierarchy('S1');

      expect(_argv(runner, 0), [
        '-s',
        'S1',
        'shell',
        'uiautomator',
        'dump',
        '/data/local/tmp/karmashala_ui_dump.xml',
      ]);
      expect(_argv(runner, 1), [
        '-s',
        'S1',
        'shell',
        'cat',
        '/data/local/tmp/karmashala_ui_dump.xml',
      ]);
      expect(_argv(runner, 2), [
        '-s',
        'S1',
        'shell',
        'rm',
        '-f',
        '/data/local/tmp/karmashala_ui_dump.xml',
      ]);
      expect(tree.nodeCount, 1);
      expect(tree.roots.single.text, 'Sign in');
    });

    test(
      'retries an idle-state failure, which exits 0 while failing',
      () async {
        final runner = runnerFor(['ERROR: could not get idle state.', dumped]);
        final tree = await service(runner).dumpUiHierarchy('S1');
        expect(tree.nodeCount, 1);
        final dumpCalls = runner.requests
            .where((r) => r.arguments.contains('uiautomator'))
            .length;
        expect(dumpCalls, 2);
      },
    );

    test('gives up after the attempt budget and says why', () async {
      final runner = runnerFor(['ERROR: could not get idle state.']);
      await expectLater(
        service(runner).dumpUiHierarchy('S1', attempts: 3),
        throwsA(
          isA<UiDumpException>()
              .having((e) => e.serial, 'serial', 'S1')
              .having((e) => e.attempts, 'attempts', 3)
              .having((e) => e.message, 'message', contains('idle')),
        ),
      );
      expect(
        runner.requests
            .where((r) => r.arguments.contains('uiautomator'))
            .length,
        3,
      );
    });

    test('does not retry a failure that will not fix itself', () async {
      final runner = runnerFor(['ERROR: could not create file /nope/x.xml']);
      await expectLater(
        service(runner).dumpUiHierarchy('S1', attempts: 3),
        throwsA(isA<UiDumpException>()),
      );
      expect(
        runner.requests
            .where((r) => r.arguments.contains('uiautomator'))
            .length,
        1,
      );
    });

    test('retries an empty hierarchy, which means mid-transition', () async {
      var attempt = 0;
      final runner = FakeCommandRunner(
        responder: (request) {
          final args = request.arguments;
          if (args.contains('uiautomator')) {
            attempt++;
            return const CommandResult(exitCode: 0, stdout: dumped, stderr: '');
          }
          if (args.contains('cat')) {
            return CommandResult(
              exitCode: 0,
              stdout: attempt == 1 ? '<hierarchy rotation="0" />' : xml,
              stderr: '',
            );
          }
          return const CommandResult(exitCode: 0, stdout: '', stderr: '');
        },
      );
      final tree = await service(runner).dumpUiHierarchy('S1');
      expect(tree.nodeCount, 1);
      expect(attempt, 2);
    });

    test('reports a cat failure without retrying', () async {
      final runner = FakeCommandRunner(
        responder: (request) => request.arguments.contains('cat')
            ? const CommandResult(
                exitCode: 1,
                stdout: '',
                stderr: 'No such file or directory',
              )
            : const CommandResult(exitCode: 0, stdout: dumped, stderr: ''),
      );
      await expectLater(
        service(runner).dumpUiHierarchy('S1'),
        throwsA(
          isA<UiDumpException>().having(
            (e) => e.message,
            'message',
            contains('No such file'),
          ),
        ),
      );
    });

    test('reads the failure off stderr too', () async {
      final runner = FakeCommandRunner(
        responder: (request) => request.arguments.contains('uiautomator')
            ? const CommandResult(
                exitCode: 0,
                stdout: '',
                stderr:
                    'ERROR: null root node returned by '
                    'UiTestAutomationBridge.',
              )
            : const CommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
      await expectLater(
        service(runner).dumpUiHierarchy('S1', attempts: 1),
        throwsA(
          isA<UiDumpException>().having(
            (e) => e.message,
            'message',
            contains('screen is'),
          ),
        ),
      );
    });
  });

  group('stopEmulator', () {
    test('asks the emulator console to quit, and waits for it to go', () async {
      var calls = 0;
      final runner = FakeCommandRunner(
        responder: (request) {
          if (request.arguments.contains('devices')) {
            calls += 1;
            // Present on the first poll, gone on the second — the console
            // answers OK long before the process has actually exited.
            return CommandResult(
              exitCode: 0,
              stdout: calls == 1
                  ? 'List of devices attached\nemulator-5554 device\n'
                  : 'List of devices attached\n',
              stderr: '',
            );
          }
          return const CommandResult(exitCode: 0, stdout: 'OK\n', stderr: '');
        },
      );
      final stopped = await AdbService(
        runner: runner,
        sdk: _sdk(),
      ).stopEmulator('emulator-5554', pollInterval: Duration.zero);

      expect(stopped, isTrue);
      expect(_argv(runner, 0), ['-s', 'emulator-5554', 'emu', 'kill']);
      expect(calls, 2);
    });

    test(
      'reports failure rather than assuming the row can be removed',
      () async {
        final runner = FakeCommandRunner(
          responder: (request) => request.arguments.contains('devices')
              ? const CommandResult(
                  exitCode: 0,
                  stdout: 'List of devices attached\nemulator-5554 device\n',
                  stderr: '',
                )
              : const CommandResult(exitCode: 0, stdout: 'OK\n', stderr: ''),
        );
        final stopped = await AdbService(runner: runner, sdk: _sdk())
            .stopEmulator(
              'emulator-5554',
              timeout: const Duration(milliseconds: 10),
              pollInterval: Duration.zero,
            );
        expect(stopped, isFalse);
      },
    );

    test('a refused kill surfaces what the console said', () async {
      final runner = FakeCommandRunner(
        responder: (request) => request.arguments.contains('devices')
            ? const CommandResult(
                exitCode: 0,
                stdout: 'List of devices attached\nemulator-5554 device\n',
                stderr: '',
              )
            : const CommandResult(
                exitCode: 1,
                stdout: '',
                stderr: 'could not connect to TCP port 5554',
              ),
      );
      await expectLater(
        AdbService(runner: runner, sdk: _sdk()).stopEmulator(
          'emulator-5554',
          timeout: const Duration(milliseconds: 10),
          pollInterval: Duration.zero,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('could not connect'),
          ),
        ),
      );
    });
  });

  group('process and forward housekeeping', () {
    test('processList asks for pids with full command lines', () async {
      final runner = FakeCommandRunner();
      await AdbService(runner: runner, sdk: _sdk()).processList('serial-1');
      expect(_argv(runner, 0), [
        '-s',
        'serial-1',
        'shell',
        'ps',
        '-A',
        '-o',
        'PID,ARGS',
      ]);
    });

    test('killPids sends one SIGKILL for the whole set', () async {
      final runner = FakeCommandRunner();
      await AdbService(
        runner: runner,
        sdk: _sdk(),
      ).killPids('serial-1', [11026, 11028]);
      expect(_argv(runner, 0), [
        '-s',
        'serial-1',
        'shell',
        'kill',
        '-9',
        '11026',
        '11028',
      ]);
    });

    test('killPids with nothing to kill runs no command', () async {
      final runner = FakeCommandRunner();
      await AdbService(runner: runner, sdk: _sdk()).killPids('serial-1', []);
      expect(runner.requests, isEmpty);
    });

    test(
      'listForwards does not pass -s, because adb ignores it there',
      () async {
        final runner = FakeCommandRunner();
        await AdbService(runner: runner, sdk: _sdk()).listForwards();
        expect(_argv(runner, 0), ['forward', '--list']);
      },
    );
  });
}

/// Turning "not enough space" into a number and a remedy: `adb install` on a
/// full emulator names neither the partition nor what to do about it.
void _installSpaceTests() {
  group('install failures about space', () {
    test('are recognised across the wordings different API levels use', () {
      expect(
        installFailedForSpace(
          'android.os.ParcelableException: java.io.IOException: '
          'Requested internal only, but not enough space',
        ),
        isTrue,
      );
      expect(
        installFailedForSpace('Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE]'),
        isTrue,
      );
      expect(installFailedForSpace('No space left on device'), isTrue);
    });

    test('and an ordinary install failure is not mistaken for one', () {
      // The remedy for this one is a different APK, not free space; saying
      // "run pm trim-caches" here would send somebody the wrong way.
      expect(
        installFailedForSpace('Failure [INSTALL_FAILED_ALREADY_EXISTS]'),
        isFalse,
      );
    });

    test('df names how full /data is', () {
      const df =
          'Filesystem      1K-blocks    Used Available Use% Mounted on\n'
          '/dev/block/dm-5   6033792 5348940    668852  89% /data\n';
      expect(dataPartitionUse(df), '89%');
    });

    test('and says nothing rather than guessing at an unfamiliar layout', () {
      // A wrong percentage in an error message is worse than no percentage.
      expect(dataPartitionUse('df: /data: Permission denied'), isNull);
      expect(dataPartitionUse(''), isNull);
    });
  });
}
