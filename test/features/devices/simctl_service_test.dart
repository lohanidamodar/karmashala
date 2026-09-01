import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/features/devices/data/simctl_service.dart';
import 'package:karmashala/src/features/devices/domain/device_action.dart';
import 'package:karmashala/src/features/devices/domain/device_input.dart';
import 'package:karmashala/src/features/devices/domain/ios_simulator.dart';

import '../../support/fake_command_runner.dart';

const _udid = '70592006-11CD-44A3-96BC-25EE8E72CA3D';

/// The argv of the nth request. These are the strings that fail silently when
/// wrong — `simctl` exits 0 for several kinds of nothing-happened — so they are
/// asserted literally rather than with `contains`.
List<String> _argv(FakeCommandRunner runner, [int index = 0]) =>
    runner.requests[index].arguments;

CommandResult _ok([String stdout = '']) =>
    CommandResult(exitCode: 0, stdout: stdout, stderr: '');

CommandResult _fails(String stderr) =>
    CommandResult(exitCode: 164, stdout: '', stderr: stderr);

SimctlService _service(
  FakeCommandRunner runner, {
  Uint8List? file,
  List<DeviceAction>? actions,
}) {
  final service = SimctlService(
    runner: runner,
    readHostFile: file == null ? null : (_) async => file,
  );
  if (actions != null) service.actionSink = actions.add;
  return service;
}

void main() {
  group('parseSimctlLaunchPid', () {
    test('reads the pid out of simctl launch output', () {
      expect(parseSimctlLaunchPid('com.example.app: 61324'), 61324);
    });

    test('ignores lines that are not a pid line', () {
      expect(
        parseSimctlLaunchPid(
          'An error was encountered processing the command\n'
          'com.example.app: 42\n',
        ),
        42,
      );
    });

    test('returns null rather than guessing at a malformed line', () {
      expect(parseSimctlLaunchPid('com.example.app: not-a-pid'), isNull);
      expect(parseSimctlLaunchPid(''), isNull);
    });
  });

  group('listSimulators', () {
    test('asks for the JSON listing and parses it', () async {
      final runner = FakeCommandRunner(
        responder: (_) => _ok('''
{
  "devices" : {
    "com.apple.CoreSimulator.SimRuntime.iOS-26-4" : [
      {
        "udid" : "$_udid",
        "isAvailable" : true,
        "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
        "state" : "Booted",
        "name" : "iPhone 17 Pro"
      }
    ]
  }
}
'''),
      );
      final simulators = await _service(runner).listSimulators();

      expect(runner.requests.single.executable, 'xcrun');
      expect(_argv(runner), ['simctl', 'list', 'devices', '-j']);
      expect(simulators.single.udid, _udid);
      expect(simulators.single.state, SimulatorState.booted);
    });

    test('returns empty rather than throwing when simctl fails', () async {
      final runner = FakeCommandRunner(
        responder: (_) => _fails('No devices are available'),
      );
      expect(await _service(runner).listSimulators(), isEmpty);
    });

    test(
      'treats a host without Xcode as "no simulators", not a crash',
      () async {
        final runner = FakeCommandRunner(
          throwError: CommandException('xcrun is not installed'),
        );
        expect(await _service(runner).listSimulators(), isEmpty);
      },
    );
  });

  group('screenSize', () {
    test('enumerates the displays and returns the phone, not the first', () async {
      // Real output from a booted iPhone 17 Pro on Xcode 26.6. The first
      // width/height pair belongs to a 720x480 display with `Display class: 1`;
      // the phone is the `Display class: 0` block. This fixture used to be one
      // I made up, which is how the parser shipped matching nothing at all.
      final runner = FakeCommandRunner(
        responder: (_) => _ok('''
Port:
    UUID: 08246516-F8D9-42CB-A4E5-CF060FFC65D7
    Class: Unknown
    Port Identifier: com.apple.display.captureservice
    Power state: On

Port:
    UUID: 847B14E3-B8EC-4BE0-9565-E8B8E956CCFD
    Class: Display
    Port Identifier: com.apple.framebuffer.display
    Power state: On
    Display class: 1
    Default width: 720
    Default height: 480
    Default pixel format: 'BGRA'

Port:
    UUID: D6162B93-A4C8-4613-AB8B-AD6959364223
    Class: Display
    Port Identifier: com.apple.framebuffer.display
    Power state: On
    Display class: 0
    Default width: 1206
    Default height: 2622
    Default pixel format: 'BGRA'
    IOSurface port:
        width              = 1206
        height             = 2622
'''),
      );
      final size = await _service(runner).screenSize(_udid);

      expect(_argv(runner), ['simctl', 'io', _udid, 'enumerate']);
      expect(size, const DeviceScreenSize(width: 1206, height: 2622));
    });

    test('returns null when simctl cannot be reached', () async {
      final runner = FakeCommandRunner(
        throwError: CommandException('xcrun is not installed'),
      );
      expect(await _service(runner).screenSize(_udid), isNull);
    });
  });

  group('screenshot', () {
    test('writes to a real path and reads the bytes back', () async {
      final runner = FakeCommandRunner();
      final actions = <DeviceAction>[];
      final bytes = await _service(
        runner,
        file: Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]),
        actions: actions,
      ).screenshot(_udid, hostPath: '/tmp/shot.png');

      expect(_argv(runner), [
        'simctl',
        'io',
        _udid,
        'screenshot',
        '/tmp/shot.png',
      ], reason: 'a "-" here would create a file called "-", not use stdout');
      expect(bytes, [0x89, 0x50, 0x4e, 0x47]);
      expect(actions.single.verb, 'screenshot');
      expect(actions.single.png, bytes);
    });

    test('reports a failed capture instead of an empty image', () async {
      final runner = FakeCommandRunner(
        responder: (_) => _fails('Invalid device state'),
      );
      final actions = <DeviceAction>[];
      await expectLater(
        _service(runner, actions: actions).screenshot(_udid, hostPath: 'x.png'),
        throwsA(isA<StateError>()),
      );
      expect(actions.single.ok, isFalse);
    });
  });

  group('boot and shutdown', () {
    test('boot sends the exact argv', () async {
      final runner = FakeCommandRunner();
      await _service(runner).boot(_udid);
      expect(_argv(runner), ['simctl', 'boot', _udid]);
    });

    test('an already booted simulator is success, not a failure', () async {
      final runner = FakeCommandRunner(
        responder: (_) =>
            _fails('Unable to boot device in current state: Booted'),
      );
      final actions = <DeviceAction>[];
      await _service(runner, actions: actions).boot(_udid);
      expect(actions.single.verb, 'boot');
      expect(actions.single.ok, isTrue);
    });

    test('a real boot failure still throws', () async {
      final runner = FakeCommandRunner(
        responder: (_) => _fails(
          'Unable to boot device because we cannot '
          'determine the runtime bundle',
        ),
      );
      final actions = <DeviceAction>[];
      await expectLater(
        _service(runner, actions: actions).boot(_udid),
        throwsA(isA<StateError>()),
      );
      expect(actions.single.ok, isFalse);
    });

    test('shutdown sends the exact argv', () async {
      final runner = FakeCommandRunner();
      await _service(runner).shutdown(_udid);
      expect(_argv(runner), ['simctl', 'shutdown', _udid]);
    });

    test('an already shut down simulator is success', () async {
      final runner = FakeCommandRunner(
        responder: (_) =>
            _fails('Unable to shutdown device in current state: Shutdown'),
      );
      await _service(runner).shutdown(_udid);
    });

    test('erase sends the exact argv', () async {
      final runner = FakeCommandRunner();
      await _service(runner).erase(_udid);
      expect(_argv(runner), ['simctl', 'erase', _udid]);
    });
  });

  group('bootAndWait', () {
    test(
      'waits for bootstatus to exit, and does not read its status',
      () async {
        final handle = FakeProcessHandle()
          ..emitStdout('Status=4294967295, isTerminal=YES');
        handle.complete(0);
        final runner = FakeCommandRunner(processFactory: (_) => handle);
        final actions = <DeviceAction>[];
        await _service(runner, actions: actions).bootAndWait(_udid);

        expect(runner.startRequests.single.executable, 'xcrun');
        expect(runner.startRequests.single.arguments, [
          'simctl',
          'bootstatus',
          _udid,
          '-b',
        ]);
        expect(actions.single.verb, 'boot');
        expect(actions.single.ok, isTrue);
      },
    );

    test(
      'kills bootstatus and reports failure when it never finishes',
      () async {
        final handle = FakeProcessHandle();
        final runner = FakeCommandRunner(processFactory: (_) => handle);
        final actions = <DeviceAction>[];
        await expectLater(
          _service(
            runner,
            actions: actions,
          ).bootAndWait(_udid, timeout: const Duration(milliseconds: 20)),
          throwsA(isA<StateError>()),
        );
        expect(handle.killed, isTrue, reason: 'must not leak the process');
        expect(actions.single.ok, isFalse);
      },
    );

    test('a non-zero exit is a failure, with the last output quoted', () async {
      final handle = FakeProcessHandle()..emitStderr('Invalid device: nope');
      handle.complete(2);
      final runner = FakeCommandRunner(processFactory: (_) => handle);
      await expectLater(
        _service(runner).bootAndWait(_udid),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Invalid device'),
          ),
        ),
      );
    });
  });

  group('apps', () {
    test('install and uninstall send the exact argv', () async {
      final runner = FakeCommandRunner();
      final service = _service(runner);
      await service.installApp(_udid, '/build/Runner.app');
      await service.uninstallApp(_udid, 'com.example.app');

      expect(_argv(runner), ['simctl', 'install', _udid, '/build/Runner.app']);
      expect(_argv(runner, 1), [
        'simctl',
        'uninstall',
        _udid,
        'com.example.app',
      ]);
    });

    test('launch returns the pid and reports the action', () async {
      final runner = FakeCommandRunner(
        responder: (_) => _ok('com.example.app: 61324\n'),
      );
      final actions = <DeviceAction>[];
      final pid = await _service(
        runner,
        actions: actions,
      ).launchApp(_udid, 'com.example.app');

      expect(_argv(runner), ['simctl', 'launch', _udid, 'com.example.app']);
      expect(pid, 61324);
      expect(actions.single.verb, 'launch');
      expect(actions.single.summary, contains('com.example.app'));
    });

    test('relaunch terminates the running process first', () async {
      final runner = FakeCommandRunner(responder: (_) => _ok('x: 1\n'));
      await _service(
        runner,
      ).launchApp(_udid, 'com.example.app', relaunch: true);
      expect(_argv(runner), [
        'simctl',
        'launch',
        '--terminate-running-process',
        _udid,
        'com.example.app',
      ]);
    });

    test('a launch line without a pid yields null, not a bogus pid', () async {
      final runner = FakeCommandRunner(responder: (_) => _ok('launched ok\n'));
      expect(
        await _service(runner).launchApp(_udid, 'com.example.app'),
        isNull,
      );
    });

    test('a failed launch surfaces as a StateError, not a crash', () async {
      final runner = FakeCommandRunner(
        responder: (_) => _fails(
          'The request to open "com.example.app" failed: application is not '
          'installed',
        ),
      );
      final actions = <DeviceAction>[];
      await expectLater(
        _service(runner, actions: actions).launchApp(_udid, 'com.example.app'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('not installed'),
          ),
        ),
      );
      expect(actions.single.ok, isFalse);
    });

    test('a missing xcrun is reported and rethrown, not swallowed', () async {
      final runner = FakeCommandRunner(
        throwError: CommandException('xcrun is not installed'),
      );
      final actions = <DeviceAction>[];
      await expectLater(
        _service(runner, actions: actions).launchApp(_udid, 'com.example.app'),
        throwsA(isA<CommandException>()),
      );
      expect(actions.single.ok, isFalse);
      expect(actions.single.detail, contains('not installed'));
    });

    test('terminate sends the exact argv', () async {
      final runner = FakeCommandRunner();
      await _service(runner).terminateApp(_udid, 'com.example.app');
      expect(_argv(runner), ['simctl', 'terminate', _udid, 'com.example.app']);
    });
  });

  group('device state', () {
    test('openUrl sends the exact argv', () async {
      final runner = FakeCommandRunner();
      await _service(runner).openUrl(_udid, 'https://example.com/a?b=c');
      expect(_argv(runner), [
        'simctl',
        'openurl',
        _udid,
        'https://example.com/a?b=c',
      ]);
    });

    test('setAppearance sends the exact argv', () async {
      final runner = FakeCommandRunner();
      await _service(runner).setAppearance(_udid, 'dark');
      expect(_argv(runner), ['simctl', 'ui', _udid, 'appearance', 'dark']);
    });

    test('setAppearance rejects anything but light or dark', () async {
      final runner = FakeCommandRunner();
      expect(
        () => _service(runner).setAppearance(_udid, 'sepia'),
        throwsA(isA<ArgumentError>()),
      );
      expect(runner.requests, isEmpty);
    });

    test('setLocation passes a lat,lon pair', () async {
      final runner = FakeCommandRunner();
      await _service(runner).setLocation(_udid, 27.7172, 85.324);
      expect(_argv(runner), [
        'simctl',
        'location',
        _udid,
        'set',
        '27.7172,85.324',
      ]);
    });

    test('push sends the payload path', () async {
      final runner = FakeCommandRunner();
      await _service(runner).push(_udid, '/tmp/payload.apns');
      expect(_argv(runner), ['simctl', 'push', _udid, '/tmp/payload.apns']);
    });

    test('addMedia sends the exact argv', () async {
      final runner = FakeCommandRunner();
      await _service(runner).addMedia(_udid, '/tmp/photo.png');
      expect(_argv(runner), ['simctl', 'addmedia', _udid, '/tmp/photo.png']);
    });
  });

  group('clipboard', () {
    test('pipes the text into pbcopy through a shell', () async {
      final runner = FakeCommandRunner();
      final actions = <DeviceAction>[];
      await _service(runner, actions: actions).setClipboard(_udid, 'hello');

      expect(runner.requests.single.executable, '/bin/sh');
      expect(_argv(runner), [
        '-c',
        "printf %s 'hello' | 'xcrun' simctl pbcopy '$_udid'",
      ]);
      expect(actions.single.verb, 'clipboard');
    });

    test('quotes text that would otherwise escape the shell string', () async {
      final runner = FakeCommandRunner();
      await _service(runner).setClipboard(_udid, "it's; rm -rf /");
      expect(
        _argv(runner)[1],
        "printf %s 'it'\\''s; rm -rf /' | 'xcrun' simctl pbcopy '$_udid'",
      );
    });

    test('readClipboard returns pbpaste output verbatim', () async {
      final runner = FakeCommandRunner(responder: (_) => _ok('copied text\n'));
      final read = await _service(runner).readClipboard(_udid);

      expect(_argv(runner), ['simctl', 'pbpaste', _udid]);
      expect(read, 'copied text\n');
    });
  });

  group('logs', () {
    test('readLog asks for a time window and drops the preamble', () async {
      final runner = FakeCommandRunner(
        responder: (_) => _ok(
          'Filtering the log data using "processImagePath CONTAINS x"\n'
          'Timestamp               Ty Process[PID:TID]\n'
          '2026-09-01 10:00:00.100 Df Runner[512:9] first\n'
          '\n'
          '2026-09-01 10:00:00.200 Df Runner[512:9] second\n',
        ),
      );
      final actions = <DeviceAction>[];
      final lines = await _service(
        runner,
        actions: actions,
      ).readLog(_udid, window: const Duration(minutes: 1));

      expect(_argv(runner), [
        'simctl',
        'spawn',
        _udid,
        'log',
        'show',
        '--style',
        'compact',
        '--last',
        '60s',
      ]);
      expect(lines, hasLength(2));
      expect(lines.last, endsWith('second'));
      expect(actions.single.verb, 'log');
    });

    test('readLog keeps the newest lines when there are too many', () async {
      final runner = FakeCommandRunner(
        responder: (_) => _ok(List.generate(10, (i) => 'line $i').join('\n')),
      );
      final lines = await _service(runner).readLog(_udid, lines: 3);
      expect(lines, ['line 7', 'line 8', 'line 9']);
    });

    test('readLog returns empty when the spawn fails', () async {
      final runner = FakeCommandRunner(
        responder: (_) => _fails('Invalid device: nope'),
      );
      expect(await _service(runner).readLog(_udid), isEmpty);
    });

    test('streamLog spawns a compact stream and kills it on cancel', () async {
      final handle = FakeProcessHandle();
      final runner = FakeCommandRunner(processFactory: (_) => handle);
      final lines = <String>[];
      final subscription = _service(runner).streamLog(_udid).listen(lines.add);
      await pumpEventQueue();

      expect(runner.startRequests.single.arguments, [
        'simctl',
        'spawn',
        _udid,
        'log',
        'stream',
        '--style',
        'compact',
      ]);

      handle.emitStdout('Runner[512:9] hello');
      await pumpEventQueue();
      expect(lines, ['Runner[512:9] hello']);

      await subscription.cancel();
      expect(handle.killed, isTrue, reason: 'a closed log panel leaks it');
    });

    test('streamLog reports a missing xcrun as a stream error', () async {
      final runner = FakeCommandRunner(
        throwError: CommandException('xcrun is not installed'),
      );
      expect(
        _service(runner).streamLog(_udid),
        emitsError(isA<CommandException>()),
      );
    });
  });

  group('actionSink', () {
    test('a broken recorder never breaks the command it watches', () async {
      final runner = FakeCommandRunner();
      final service = _service(runner)
        ..actionSink = (_) => throw StateError('recorder is broken');
      await service.boot(_udid);
      expect(runner.requests, hasLength(1));
    });

    test('plumbing reads are not recorded as things somebody did', () async {
      final runner = FakeCommandRunner(responder: (_) => _ok('{}'));
      final actions = <DeviceAction>[];
      final service = _service(runner, actions: actions);
      await service.listSimulators();
      await service.screenSize(_udid);
      expect(actions, isEmpty);
    });

    test('every user-visible verb reaches the sink', () async {
      final runner = FakeCommandRunner(responder: (_) => _ok('app: 7'));
      final actions = <DeviceAction>[];
      final service = _service(runner, actions: actions);
      await service.boot(_udid);
      await service.launchApp(_udid, 'com.example.app');
      await service.openUrl(_udid, 'https://example.com');
      await service.setAppearance(_udid, 'light');
      await service.setLocation(_udid, 1, 2);
      await service.terminateApp(_udid, 'com.example.app');
      await service.shutdown(_udid);

      expect(actions.map((a) => a.verb), [
        'boot',
        'launch',
        'openUrl',
        'appearance',
        'location',
        'terminate',
        'shutdown',
      ]);
      expect(actions.every((a) => a.serial == _udid), isTrue);
      expect(actions.every((a) => a.ok), isTrue);
    });
  });
}
