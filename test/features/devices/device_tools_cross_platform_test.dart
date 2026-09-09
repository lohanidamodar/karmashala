import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/devices/application/device_providers.dart';
import 'package:karmashala/src/features/devices/application/ios_device_providers.dart';
import 'package:karmashala/src/features/devices/domain/android_device.dart';
import 'package:karmashala/src/features/devices/data/wda_backend.dart';
import 'package:karmashala/src/features/devices/domain/simulator_backend.dart';
import 'package:karmashala/src/features/devices/domain/ui_node.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';

import '../../support/fake_command_runner.dart';
import '../../support/temp_directory.dart';

/// The `device_*` tools driven the way the bridge drives them — a real
/// `POST /rpc` against a real [LauncherControlServer] — with **both** an
/// Android device and an iOS simulator faked underneath.
///
/// The point of the file is the seam. These tools used to reach `AdbService`
/// directly and take an Android serial; they now resolve a `DeviceDriver` from
/// whatever id they were handed, which means every assertion here is really
/// asking one of two questions: does an Android caller still get exactly what
/// it got before, and does a simulator udid reach the simulator engine with the
/// right arguments in the right coordinate space.

// ---------------------------------------------------------------------------
// A simulator's screen, as WebDriverAgent describes it
//
// Two facts are load-bearing and both come from a real device. The frames are
// in POINTS — 402x874 on an iPhone 17 Pro whose backing store is 1206x2622 —
// and the Application element carries the bundle id in `name`, which is the
// only thing on an iOS tree that says which app is in front.
// ---------------------------------------------------------------------------
UiHierarchy _wdaTree() => UiHierarchy(
  roots: [
    UiNode(
      index: 0,
      className: 'Application',
      resourceId: 'com.example.Probe',
      bounds: const UiBounds(left: 0, top: 0, right: 402, bottom: 874),
      children: [
        UiNode(
          index: 0,
          className: 'StaticText',
          text: 'Hello simulator',
          bounds: const UiBounds(left: 40, top: 200, right: 362, bottom: 240),
        ),
        UiNode(
          index: 1,
          className: 'TextField',
          resourceId: 'probe-field',
          clickable: true,
          bounds: const UiBounds(left: 40, top: 300, right: 362, bottom: 344),
        ),
        UiNode(
          index: 2,
          className: 'Button',
          text: 'Continue',
          clickable: true,
          bounds: const UiBounds(left: 40, top: 400, right: 362, bottom: 444),
        ),
      ],
    ),
  ],
);

/// A [SimulatorBackend] that records rather than acts.
///
/// Declared against [WdaBackend] because that is the type
/// `simulatorBackendProvider` hands out — the same trick `device_pane_test`
/// uses — while everything the driver calls is on the [SimulatorBackend]
/// interface.
class _RecordingBackend implements WdaBackend {
  _RecordingBackend(this.events);

  /// Shared with the host's command log, so a test can assert on the order of
  /// things that happen in two different objects.
  final List<String> events;

  final List<String> taps = [];
  final List<String> typed = [];
  final List<SimulatorKey> pressedKeys = [];
  final List<SimulatorButton> pressedButtons = [];

  @override
  String get id => 'fake';

  @override
  String get displayName => 'Fake backend';

  @override
  Future<void> attach(String udid) async => events.add('attach $udid');

  @override
  Future<void> tap(String udid, int x, int y) async => taps.add('$udid:$x,$y');

  @override
  Future<void> inputText(String udid, String text) async => typed.add(text);

  @override
  Future<void> pressKey(String udid, SimulatorKey key) async =>
      pressedKeys.add(key);

  @override
  Future<void> pressButton(String udid, SimulatorButton button) async =>
      pressedButtons.add(button);

  @override
  Future<UiHierarchy> describeUi(String udid) async => _wdaTree();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}

// ---------------------------------------------------------------------------
// The host: one command runner standing in for adb, xcrun and plutil
// ---------------------------------------------------------------------------

const _adbPath = '/sdk/platform-tools/adb';
const _emulatorPath = '/sdk/emulator/emulator';

AndroidSdk _sdk() => const AndroidSdk(
  root: EnvironmentPath(environmentId: 'localPosix', path: '/sdk'),
  adb: EnvironmentPath(environmentId: 'localPosix', path: _adbPath),
  emulator: EnvironmentPath(environmentId: 'localPosix', path: _emulatorPath),
);

/// A fake macOS host with a scriptable device set.
class _Host {
  _Host({
    List<String> androidSerials = const [],
    this.physicalSerials = const [],
    Map<String, String>? simulatorStates,
  }) : androidSerials = [...androidSerials],
       simulatorStates =
           simulatorStates ?? {'UDID-17PRO': 'Booted', 'UDID-16': 'Shutdown'};

  /// Mutable: `emu kill` takes one away, which is the only way `stopEmulator`
  /// can tell that the emulator actually went rather than that the console
  /// merely said OK.
  final List<String> androidSerials;
  final List<String> physicalSerials;

  /// udid → simctl's word for what it is doing. Mutable, because booting has to
  /// change what the next listing says or `device_boot` cannot report whether
  /// it worked.
  final Map<String, String> simulatorStates;

  /// `am start` output, so a test can reproduce the trap where it exits 0 and
  /// says `Error:` on stdout.
  String amStartOutput = 'Starting: Intent { … }';

  /// Whether `adb install` should report a failure the way old adb does:
  /// exit 0, with `Failure [...]` in the output.
  bool installFailsQuietly = false;

  /// AVDs the SDK knows about. A name, not a device: it exists whether or not
  /// anything is running, which is the whole reason the stop verb takes one.
  List<String> avdNames = ['Pixel_8_Pro_API_34'];

  /// The pid `pidof` reports for any package, or null for "not running".
  int? packagePid;

  /// Raw `logcat -d` output.
  String logcatOutput = '';

  final List<CommandRequest> commands = [];

  /// Command lines and backend calls in one list, in the order they happened.
  final List<String> events = [];

  static const Map<String, String> _simulatorNames = {
    'UDID-17PRO': 'iPhone 17 Pro',
    'UDID-16': 'iPhone 16',
    'UDID-DUP-A': 'iPhone 16',
    'UDID-DUP-B': 'iPhone 16',
  };

  static const Map<String, String> _simulatorRuntimes = {
    'UDID-17PRO': 'com.apple.CoreSimulator.SimRuntime.iOS-26-4',
    'UDID-16': 'com.apple.CoreSimulator.SimRuntime.iOS-18-2',
    'UDID-DUP-A': 'com.apple.CoreSimulator.SimRuntime.iOS-26-4',
    'UDID-DUP-B': 'com.apple.CoreSimulator.SimRuntime.iOS-18-2',
  };

  String _simctlListJson() {
    final byRuntime = <String, List<Map<String, Object?>>>{};
    for (final entry in simulatorStates.entries) {
      final runtime = _simulatorRuntimes[entry.key]!;
      byRuntime.putIfAbsent(runtime, () => []).add({
        'udid': entry.key,
        'name': _simulatorNames[entry.key]!,
        'state': entry.value,
        'isAvailable': true,
        'deviceTypeIdentifier':
            'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro',
      });
    }
    return jsonEncode({'devices': byRuntime});
  }

  CommandResult _simctl(CommandRequest request) {
    final args = request.arguments;
    if (args.length >= 2 && args[1] == 'list') {
      return CommandResult(exitCode: 0, stdout: _simctlListJson(), stderr: '');
    }
    if (args.contains('enumerate')) {
      // The shape `parseSimctlScreenSize` insists on: the internal display is
      // the one with `Display class: 0`, not the first block in the output.
      return const CommandResult(
        exitCode: 0,
        stdout: '''
Port: com.apple.iphonesimulator.rgba
  Class: Display
  Default height: 480
  Default width: 720
  Display class: 1

Port: com.apple.iphonesimulator.rgba
  Class: Display
  Default height: 2622
  Default width: 1206
  Display class: 0
''',
        stderr: '',
      );
    }
    if (args.contains('screenshot')) {
      // The service reads the file back, because `simctl io … screenshot -`
      // writes a file literally named `-` rather than to stdout.
      File(
        args.last,
      ).writeAsBytesSync(Uint8List.fromList(const [0x89, 0x50, 0x4E, 0x47]));
      return const CommandResult(exitCode: 0, stdout: '', stderr: '');
    }
    if (args.contains('launch')) {
      return const CommandResult(
        exitCode: 0,
        stdout: 'com.example.Probe: 4242',
        stderr: '',
      );
    }
    if (args.contains('shutdown')) {
      simulatorStates[args[2]] = 'Shutdown';
      return const CommandResult(exitCode: 0, stdout: '', stderr: '');
    }
    if (args.contains('log')) {
      return const CommandResult(
        exitCode: 0,
        stdout:
            'Filtering the log data using "…"\n'
            '2026-09-02 10:00:00.1 Df Probe[4242] hello from the probe\n'
            '2026-09-02 10:00:00.2 Df backboardd[91] something else\n',
        stderr: '',
      );
    }
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  CommandResult _adb(CommandRequest request) {
    final args = request.arguments;
    if (args.contains('devices')) {
      final rows = [
        for (final serial in androidSerials)
          '$serial  device product:sdk model:Pixel transport_id:7',
        for (final serial in physicalSerials)
          '$serial  device product:phone model:Handset transport_id:8',
      ];
      return CommandResult(
        exitCode: 0,
        stdout: 'List of devices attached\n${rows.join('\n')}\n',
        stderr: '',
      );
    }
    if (args.contains('pull')) {
      // `screenshot` goes device-file → `adb pull` → host-file, and then reads
      // the host file. Without this the case only ever passed on a machine
      // where an earlier real run had left that PNG in the temp directory.
      File(
        args.last,
      ).writeAsBytesSync(Uint8List.fromList(const [0x89, 0x50, 0x4E, 0x47]));
      return const CommandResult(exitCode: 0, stdout: '', stderr: '');
    }
    if (args.contains('wm')) {
      return const CommandResult(
        exitCode: 0,
        stdout: 'Physical size: 1080x2400',
        stderr: '',
      );
    }
    if (args.contains('install')) {
      return CommandResult(
        exitCode: 0,
        stdout: installFailsQuietly
            ? 'Failure [INSTALL_FAILED_TEST_ONLY]'
            : 'Success',
        stderr: '',
      );
    }
    if (args.contains('am')) {
      if (args.contains('start')) {
        return CommandResult(exitCode: 0, stdout: amStartOutput, stderr: '');
      }
      return const CommandResult(exitCode: 0, stdout: '', stderr: '');
    }
    if (args.contains('-list-avds')) {
      return CommandResult(
        exitCode: 0,
        stdout: avdNames.join('\n'),
        stderr: '',
      );
    }
    if (args.contains('avd')) {
      // `emu avd name` — how a running emulator says which AVD it booted.
      return CommandResult(
        exitCode: 0,
        stdout: '${avdNames.isEmpty ? '' : avdNames.first}\nOK',
        stderr: '',
      );
    }
    if (args.contains('pidof')) {
      return CommandResult(
        exitCode: packagePid == null ? 1 : 0,
        stdout: packagePid == null ? '' : '$packagePid',
        stderr: '',
      );
    }
    if (args.contains('logcat')) {
      return CommandResult(exitCode: 0, stdout: logcatOutput, stderr: '');
    }
    if (args.contains('emu')) {
      androidSerials.remove(args[1]);
      return const CommandResult(exitCode: 0, stdout: 'OK', stderr: '');
    }
    if (args.contains('monkey')) {
      return const CommandResult(
        exitCode: 0,
        stdout: 'Events injected: 1',
        stderr: '',
      );
    }
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  FakeCommandRunner runner({bool measure = false}) {
    CommandResult responder(CommandRequest request) {
      commands.add(request);
      events.add('${request.executable} ${request.arguments.join(' ')}');
      if (request.executable == 'xcrun') return _simctl(request);
      if (request.executable == '/usr/bin/plutil') {
        return const CommandResult(
          exitCode: 0,
          stdout: 'com.example.Probe\n',
          stderr: '',
        );
      }
      if (request.executable == _adbPath) return _adb(request);
      if (request.executable == _emulatorPath) {
        if (request.arguments.contains('-list-avds')) {
          return CommandResult(
            exitCode: 0,
            stdout: avdNames.join('\n'),
            stderr: '',
          );
        }
        return const CommandResult(exitCode: 0, stdout: '', stderr: '');
      }
      return const CommandResult(exitCode: 0, stdout: '', stderr: '');
    }

    FakeProcessHandle processFactory(CommandRequest request) {
      commands.add(request);
      final handle = FakeProcessHandle();
      // `bootstatus` signals completion by exiting; a handle that never exits
      // is a boot that never finishes.
      if (request.arguments.contains('bootstatus')) {
        simulatorStates[request.arguments[2]] = 'Booted';
      }
      handle.complete();
      return handle;
    }

    return measure
        ? _ConcurrencyRunner(
            environmentId: 'localPosix',
            responder: responder,
            processFactory: processFactory,
          )
        : FakeCommandRunner(
            environmentId: 'localPosix',
            responder: responder,
            processFactory: processFactory,
          );
  }

  /// Every command line seen, for asserting on what was actually run.
  List<String> get commandLines => [
    for (final request in commands)
      '${request.executable} ${request.arguments.join(' ')}',
  ];
}

/// A [FakeCommandRunner] that records how many commands were in flight at once.
///
/// Every command yields once before answering, so anything the caller started
/// together is observably together — and a caller that awaits its probes one at
/// a time never gets past a peak of one.
class _ConcurrencyRunner extends FakeCommandRunner {
  _ConcurrencyRunner({
    required super.environmentId,
    super.responder,
    super.processFactory,
  });

  int _inFlight = 0;
  int peak = 0;

  @override
  Future<CommandResult> run(CommandRequest request) async {
    _inFlight++;
    if (_inFlight > peak) {
      peak = _inFlight;
    }
    await Future<void>.delayed(Duration.zero);
    final result = await super.run(request);
    _inFlight--;
    return result;
  }
}

typedef _Rpc =
    Future<Map<String, dynamic>> Function(String, [Map<String, Object?>]);

Future<
  ({
    _Rpc call,
    Future<void> Function() dispose,
    _RecordingBackend backend,
    FakeCommandRunner runner,
  })
>
_server(
  _Host host, {
  bool androidSdk = true,
  bool wda = true,
  Duration sdkDiscovery = Duration.zero,
  bool awaitSdk = true,
  bool measureConcurrency = false,
}) async {
  final backend = _RecordingBackend(host.events);
  final runner = host.runner(measure: measureConcurrency);
  final container = ProviderContainer(
    overrides: [
      commandRunnerFactoryProvider.overrideWithValue(
        FakeCommandRunnerFactory(fallback: runner),
      ),
      androidSdkProvider.overrideWith((ref) async {
        if (sdkDiscovery > Duration.zero) {
          await Future<void>.delayed(sdkDiscovery);
        }
        return androidSdk ? _sdk() : null;
      }),
      hostCanRunSimulatorsProvider.overrideWithValue(true),
      // Slimming is a user preference read from the settings repository, which
      // wants a real preference store this test has no reason to stand up. It
      // is also not what any of these tests is about: it writes a plist before
      // the boot and changes nothing about what device_boot reports.
      slimmingOnStartProvider.overrideWithValue(false),
      simulatorBackendProvider.overrideWithValue(wda ? backend : null),
    ],
  );
  // Normally resolved up front so the tools are not racing discovery; a test
  // that is *about* that race asks for it not to be.
  if (awaitSdk) await container.read(androidSdkProvider.future);
  final directory = await Directory.systemTemp.createTemp('cg_dev_tools');
  final bridgeFile = '${directory.path}${Platform.pathSeparator}bridge.json';
  final server = LauncherControlServer(container);
  await server.start(bridgeFilePath: bridgeFile, useLocalSocket: false);
  final handshake =
      jsonDecode(File(bridgeFile).readAsStringSync()) as Map<String, dynamic>;
  final client = HttpClient();

  Future<Map<String, dynamic>> call(
    String tool, [
    Map<String, Object?> arguments = const {},
  ]) async {
    final request = await client.post(
      '127.0.0.1',
      handshake['port'] as int,
      '/rpc',
    );
    request.headers.set('authorization', 'Bearer ${handshake['token']}');
    request.write(jsonEncode({'tool': tool, 'arguments': arguments}));
    final response = await request.close();
    return jsonDecode(await utf8.decoder.bind(response).join())
        as Map<String, dynamic>;
  }

  Future<void> dispose() async {
    client.close(force: true);
    await server.stop();
    container.dispose();
    await directory.delete(recursive: true);
  }

  return (call: call, dispose: dispose, backend: backend, runner: runner);
}

Map<String, dynamic> _ok(Map<String, dynamic> reply) {
  expect(reply['ok'], isTrue, reason: 'RPC failed: ${reply['error']}');
  return reply['result'] as Map<String, dynamic>;
}

String _text(Map<String, dynamic> reply) {
  final content = _ok(reply)['_mcpContent'] as List;
  return [
    for (final block in content)
      if ((block as Map)['type'] == 'text') block['text'] as String,
  ].join('\n');
}

String _error(Map<String, dynamic> reply) {
  expect(
    reply['ok'],
    isFalse,
    reason: 'expected a refusal, got ${reply['result']}',
  );
  return reply['error'] as String;
}

void main() {
  group('one vocabulary', _vocabularyTests);
  group('driving a simulator', _drivingTests);
  group('refusing rather than pretending', _refusalTests);
  group('install, launch and the loop they make', _loopTests);
  group('lifecycle', _lifecycleTests);
  group('what one listing costs', _costTests);
}

void _vocabularyTests() {
  test('list_devices reports Android and simulators side by side', () async {
    final host = _Host(androidSerials: ['emulator-5554']);
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    final result = _ok(await rpc.call('list_devices'));
    final devices = result['devices'] as List;
    final simulators = result['simulators'] as List;

    // The Android half is exactly what it always was — the keys existing
    // callers read are untouched.
    expect(devices, hasLength(1));
    expect((devices.single as Map)['serial'], 'emulator-5554');
    expect((devices.single as Map)['screenSize'], '1080x2400');
    expect(result['avds'], isA<List>());

    // The iOS half is new, keyed by udid, and says which is running.
    final byUdid = <String, Map<String, Object?>>{
      for (final row in simulators.cast<Map<String, Object?>>())
        row['udid']! as String: row,
    };
    expect(byUdid.keys, containsAll(<String>['UDID-17PRO', 'UDID-16']));
    expect(byUdid['UDID-17PRO']!['running'], isTrue);
    expect(byUdid['UDID-16']!['running'], isFalse);
    expect(byUdid['UDID-17PRO']!['runtime'], 'iOS 26.4');

    // And the two coordinate spaces are named, because the numbers do not say.
    expect((devices.single as Map)['coordinateSpace'], 'device px');
    expect(byUdid['UDID-17PRO']!['coordinateSpace'], 'points');
  });

  test('a Mac with no Android SDK still lists its simulators', () async {
    // list_devices used to require adb and threw without it, so on a Mac with
    // Xcode and no SDK the one tool whose job is to say what exists refused to
    // say anything at all.
    final host = _Host();
    final rpc = await _server(host, androidSdk: false);
    addTearDown(rpc.dispose);

    final result = _ok(await rpc.call('list_devices'));
    expect(result['devices'], isEmpty);
    expect(result['simulators'], isNotEmpty);
    expect(result['androidNote'], contains('ANDROID_HOME'));
  });

  test('an SDK still being looked for is not an SDK that is missing', () async {
    // Locating the SDK means running `adb --version` and `emulator -version` —
    // process spawns, in flight for a second or two on a cold start. The
    // provider reads null for "not found" and for "not yet", and reporting the
    // second as the first told an agent there was no Android SDK on a machine
    // that has one. Observed on this machine: two consecutive runs, one listing
    // the SDK and one denying it, decided only by how long the app had been up.
    final host = _Host(androidSerials: ['emulator-5554']);
    final rpc = await _server(
      host,
      sdkDiscovery: const Duration(milliseconds: 300),
      awaitSdk: false,
    );
    addTearDown(rpc.dispose);

    final result = _ok(await rpc.call('list_devices'));
    expect(
      result['androidNote'],
      isNull,
      reason: 'claimed there was no SDK while it was still looking for one',
    );
    expect(result['devices'], hasLength(1));
  });

  test(
    'a device that appears after the first call is seen by the second',
    () async {
      // The listings are memoised so one tool call does not ask adb four times.
      // When that memo outlived the call, device_boot started an emulator,
      // reported it booted, and the next device_install_app answered "No Android
      // devices are connected" from the empty list taken before the boot — seen
      // for real against Pixel_8_Pro_API_34.
      final host = _Host(simulatorStates: {'UDID-16': 'Shutdown'});
      final rpc = await _server(host);
      addTearDown(rpc.dispose);

      expect(_ok(await rpc.call('list_devices'))['devices'], isEmpty);

      host.androidSerials.add('emulator-5554');

      final after = _ok(await rpc.call('list_devices'))['devices'] as List;
      expect(
        after,
        hasLength(1),
        reason:
            'the fleet answered from a listing taken before the device came',
      );
      // …and it is drivable, not merely listed.
      _ok(
        await rpc.call('device_tap', {
          'serial': 'emulator-5554',
          'x': 1,
          'y': 2,
        }),
      );
    },
  );

  test('the same verb takes a serial or a udid', () async {
    final host = _Host(androidSerials: ['emulator-5554']);
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    _ok(
      await rpc.call('device_tap', {'serial': 'emulator-5554', 'x': 1, 'y': 2}),
    );
    _ok(await rpc.call('device_tap', {'serial': 'UDID-17PRO', 'x': 3, 'y': 4}));
    // …and `udid`, which is the word list_devices used for it.
    _ok(await rpc.call('device_tap', {'udid': 'UDID-17PRO', 'x': 5, 'y': 6}));

    expect(
      host.commandLines,
      contains('$_adbPath -s emulator-5554 shell input tap 1 2'),
    );
    expect(rpc.backend.taps, ['UDID-17PRO:3,4', 'UDID-17PRO:5,6']);
  });

  test('a simulator can be named instead of spelled out as a udid', () async {
    final host = _Host();
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    final result = _ok(
      await rpc.call('device_tap', {
        'serial': 'iPhone 17 Pro',
        'x': 10,
        'y': 20,
      }),
    );
    expect(result['serial'], 'UDID-17PRO');
    expect(rpc.backend.taps, ['UDID-17PRO:10,20']);
  });

  test('an ambiguous simulator name is refused, not guessed', () async {
    // Two simulators can share a name across runtimes, and booting the iOS 18
    // one when the task meant iOS 26 is a wrong answer that looks right.
    final host = _Host(
      simulatorStates: {'UDID-DUP-A': 'Booted', 'UDID-DUP-B': 'Booted'},
    );
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    final error = _error(
      await rpc.call('device_tap', {'serial': 'iPhone 16', 'x': 1, 'y': 2}),
    );
    expect(error, contains('names 2 simulators'));
    expect(error, contains('UDID-DUP-A'));
    expect(error, contains('UDID-DUP-B'));
    expect(rpc.backend.taps, isEmpty);
  });

  test(
    'with one booted simulator and nothing else, the id can be left out',
    () async {
      final host = _Host();
      final rpc = await _server(host);
      addTearDown(rpc.dispose);

      final result = _ok(await rpc.call('device_tap', {'x': 7, 'y': 8}));
      expect(result['serial'], 'UDID-17PRO');
      expect(result['platform'], 'ios');
    },
  );

  test(
    'two ready devices across platforms refuse to be guessed between',
    () async {
      final host = _Host(androidSerials: ['emulator-5554']);
      final rpc = await _server(host);
      addTearDown(rpc.dispose);

      final error = _error(await rpc.call('device_tap', {'x': 1, 'y': 2}));
      expect(error, contains('2 devices are ready'));
      expect(error, contains('emulator-5554'));
      expect(error, contains('UDID-17PRO'));
    },
  );
}

void _drivingTests() {
  test('device_ui_dump reads the simulator tree, in points', () async {
    final host = _Host();
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    final text = _text(await rpc.call('device_ui_dump'));
    // The screen is the Application element's own frame — points, not the
    // 1206x2622 backing store simctl reports.
    expect(text, contains('screen 402x874 points'));
    expect(text, contains('POINTS'));
    // The bundle id, which on an iOS tree is the only thing that names the app.
    expect(text, contains('com.example.Probe'));
    expect(text, contains('Hello simulator'));
    expect(text, contains('Continue'));
  });

  test('device_tap_element taps the point the tree gave, not a pixel', () async {
    final host = _Host();
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    final text = _text(
      await rpc.call('device_tap_element', {'text': 'Continue'}),
    );
    // Centre of [40,400]-[362,444] in points. The same element in pixels would
    // be (603, 1266) on this 3x device, which is off the bottom of a 874-point
    // screen — the failure this coordinate space exists to prevent.
    expect(rpc.backend.taps, ['UDID-17PRO:201,422']);
    expect(text, contains('(201, 422) points'));
  });

  test('device_type goes to the backend, not to simctl', () async {
    final host = _Host();
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    _ok(await rpc.call('device_type', {'text': 'hello'}));
    expect(rpc.backend.typed, ['hello']);
  });

  test(
    'enter, tab and delete are pressed as keys, never typed as text',
    () async {
      // Measured against WebDriverAgent: `/wda/keys` transliterates a named key
      // into a character, so a key sent as text can arrive as an invisible code
      // point instead of moving the caret. Typing a key name looks like it works
      // and does not.
      final host = _Host();
      final rpc = await _server(host);
      addTearDown(rpc.dispose);

      for (final key in const ['enter', 'tab', 'delete']) {
        _ok(await rpc.call('device_key', {'key': key}));
      }
      expect(rpc.backend.pressedKeys, [
        SimulatorKey.returnKey,
        SimulatorKey.tab,
        SimulatorKey.backspace,
      ]);
      expect(
        rpc.backend.typed,
        isEmpty,
        reason: 'a named key must never be delivered as text',
      );
    },
  );

  test('home and power are the buttons the hardware has', () async {
    final host = _Host();
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    _ok(await rpc.call('device_key', {'key': 'home'}));
    _ok(await rpc.call('device_key', {'key': 'power'}));
    expect(rpc.backend.pressedButtons, [
      SimulatorButton.home,
      SimulatorButton.lock,
    ]);
  });

  test(
    'a simulator screenshot warns that it is not in tap coordinates',
    () async {
      final host = _Host();
      final rpc = await _server(host);
      addTearDown(rpc.dispose);

      final text = _text(await rpc.call('device_screenshot'));
      expect(text, contains('1206x2622 device px'));
      expect(text, contains('WARNING'));
      expect(text, contains('points'));
    },
  );

  test('an Android screenshot says the two spaces agree', () async {
    final host = _Host(
      androidSerials: ['emulator-5554'],
      simulatorStates: {'UDID-16': 'Shutdown'},
    );
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    final text = _text(await rpc.call('device_screenshot'));
    expect(text, contains('same space as this image'));
    expect(text, isNot(contains('WARNING')));
  });

  test(
    'device_logcat reads a simulator log and admits how it filtered',
    () async {
      final host = _Host();
      final rpc = await _server(host);
      addTearDown(rpc.dispose);

      final result = _ok(await rpc.call('device_logcat', {'package': 'Probe'}));
      expect(result['lines'], hasLength(1));
      expect(
        (result['lines'] as List).single,
        contains('hello from the probe'),
      );
      expect(result['note'], contains('plain substring'));
      // The `log show` preamble is not a log line and must not be counted as one.
      expect(
        (result['lines'] as List).any(
          (l) => '$l'.contains('Filtering the log'),
        ),
        isFalse,
      );
    },
  );
}

void _refusalTests() {
  test('back on iOS refuses by name and presses nothing', () async {
    final host = _Host();
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    final error = _error(await rpc.call('device_key', {'key': 'back'}));
    expect(error, contains('no system back button'));
    expect(error, contains('device_find_elements'));
    expect(rpc.backend.pressedButtons, isEmpty);
    expect(rpc.backend.pressedKeys, isEmpty);
    expect(rpc.backend.typed, isEmpty);
  });

  test('recents on iOS refuses, and says why a swipe would not work', () async {
    final host = _Host();
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    final error = _error(await rpc.call('device_key', {'key': 'recents'}));
    expect(error, contains('app switcher'));
    expect(error, contains('SpringBoard'));
    expect(rpc.backend.pressedButtons, isEmpty);
  });

  test('back on Android is still just a key press', () async {
    final host = _Host(
      androidSerials: ['emulator-5554'],
      simulatorStates: {'UDID-16': 'Shutdown'},
    );
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    _ok(await rpc.call('device_key', {'key': 'back'}));
    expect(
      host.commandLines,
      contains('$_adbPath -s emulator-5554 shell input keyevent KEYCODE_BACK'),
    );
  });

  test('an empty Android log says which of the two reasons it was', () async {
    // Empty has two causes that call for opposite next moves — launch the app,
    // or lower the level — and the tool used to assert the first without
    // checking. On a live emulator it told a caller an app with pid 4866 was
    // not running, when the truth was that it had logged nothing at `error`.
    final host = _Host(
      androidSerials: ['emulator-5554'],
      simulatorStates: {'UDID-16': 'Shutdown'},
    )..packagePid = 4866;
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    final running = _ok(
      await rpc.call('device_logcat', {
        'package': 'com.example.app',
        'level': 'error',
      }),
    );
    expect(running['lines'], isEmpty);
    expect(running['note'], contains('is running, but logged nothing'));
    expect(running['note'], contains('error'));

    host.packagePid = null;
    final absent = _ok(
      await rpc.call('device_logcat', {'package': 'com.example.app'}),
    );
    expect(absent['note'], contains('is not running'));
  });

  test(
    'device_logcat refuses a level on iOS instead of guessing one',
    () async {
      final host = _Host();
      final rpc = await _server(host);
      addTearDown(rpc.dispose);

      final error = _error(
        await rpc.call('device_logcat', {'level': 'warning'}),
      );
      expect(error, contains('cannot be filtered by level'));
      expect(error, contains('Default/Info/Debug/Error/Fault'));
    },
  );

  test(
    'a build with no WebDriverAgent loses three verbs, not the device',
    () async {
      final host = _Host();
      final rpc = await _server(host, wda: false);
      addTearDown(rpc.dispose);

      for (final tool in const [
        'device_tap',
        'device_ui_dump',
        'device_type',
      ]) {
        final error = _error(
          await rpc.call(tool, {'x': 1, 'y': 2, 'text': 'x'}),
        );
        expect(error, contains('no WebDriverAgent'), reason: tool);
        // The refusal names what still works. "Unsupported" would send an agent
        // away from a platform that can still do most of the loop.
        expect(error, contains('device_install_app'), reason: tool);
        expect(error, contains('device_boot'), reason: tool);
      }
      // …and those really do still work.
      _ok(await rpc.call('device_screenshot'));
      _ok(await rpc.call('device_logcat'));
    },
  );

  test('a physical Android device cannot be stopped', () async {
    final host = _Host(
      physicalSerials: ['R58M1234'],
      simulatorStates: {'UDID-16': 'Shutdown'},
    );
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    final error = _error(
      await rpc.call('device_stop_emulator', {'serial': 'R58M1234'}),
    );
    expect(error, contains('physical device'));
    expect(
      host.commandLines.any((line) => line.contains('emu kill')),
      isFalse,
      reason: 'a refusal must not have already tried',
    );
  });

  test('an unknown id says what there is instead', () async {
    final host = _Host();
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    final error = _error(
      await rpc.call('device_tap', {'serial': 'nope', 'x': 1, 'y': 2}),
    );
    expect(error, contains('No device is called "nope"'));
    expect(error, contains('iPhone 17 Pro'));
  });

  test('a shut-down simulator is not silently treated as drivable', () async {
    final host = _Host();
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    final error = _error(
      await rpc.call('device_tap', {'serial': 'UDID-16', 'x': 1, 'y': 2}),
    );
    expect(error, contains('is shut down'));
    expect(error, contains('device_boot'));
    expect(rpc.backend.taps, isEmpty);
  });
}

void _loopTests() {
  test('installing a .app reports the bundle id to launch it with', () async {
    final host = _Host();
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    final bundle = await Directory.systemTemp.createTemp('Probe');
    final appPath = '${bundle.path}${Platform.pathSeparator}Probe.app';
    Directory(appPath).createSync();
    addTearDown(() => removeTempDirectory(bundle));

    final result = _ok(await rpc.call('device_install_app', {'path': appPath}));
    // Without this the next step is "now tell me the bundle id", which the
    // caller usually does not know — it is generated by the build.
    expect(result['appId'], 'com.example.Probe');
    expect(result['note'], contains('com.example.Probe'));
    expect(
      host.commandLines,
      contains('xcrun simctl install UDID-17PRO $appPath'),
    );
  });

  test('launching on a simulator returns the pid simctl printed', () async {
    final host = _Host();
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    final result = _ok(
      await rpc.call('device_launch_app', {
        'appId': 'com.example.Probe',
        'relaunch': true,
      }),
    );
    expect(result['pid'], 4242);
    expect(
      host.commandLines,
      contains(
        'xcrun simctl launch --terminate-running-process UDID-17PRO '
        'com.example.Probe',
      ),
    );
  });

  test('the driving engine is attached before the app is launched', () async {
    // Order, not presence. WebDriverAgent is an app: starting it takes the
    // foreground, so attaching *after* a launch replaces the app that was just
    // launched and the first ui_dump of a session reports the home screen —
    // which is exactly what a real iPhone 17 Pro did before this was fixed.
    final host = _Host();
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    _ok(await rpc.call('device_launch_app', {'appId': 'com.example.Probe'}));
    final attached = host.events.indexOf('attach UDID-17PRO');
    final launched = host.events.indexWhere(
      (e) => e.startsWith('xcrun simctl launch'),
    );
    expect(attached, greaterThanOrEqualTo(0), reason: 'never attached');
    expect(launched, greaterThanOrEqualTo(0), reason: 'never launched');
    expect(
      attached,
      lessThan(launched),
      reason: 'the runner must be up before the app it is meant to drive',
    );
  });

  test('an .ipa is refused with the reason, before simctl sees it', () async {
    final host = _Host();
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    final error = _error(
      await rpc.call('device_install_app', {'path': '/tmp/Runner.ipa'}),
    );
    expect(error, contains('device slice'));
    expect(error, contains('--simulator'));
    expect(
      host.commandLines.any((line) => line.contains('simctl install')),
      isFalse,
    );
  });

  test('an .apk aimed at a simulator is refused, and vice versa', () async {
    final host = _Host(androidSerials: ['emulator-5554']);
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    expect(
      _error(
        await rpc.call('device_install_app', {
          'serial': 'UDID-17PRO',
          'path': '/tmp/app.apk',
        }),
      ),
      contains('is an Android build'),
    );
    expect(
      _error(
        await rpc.call('device_install_app', {
          'serial': 'emulator-5554',
          'path': '/tmp/Runner.app',
        }),
      ),
      contains('is an iOS build'),
    );
  });

  test('adb install keeps data and allows a debug build', () async {
    final host = _Host(
      androidSerials: ['emulator-5554'],
      simulatorStates: {'UDID-16': 'Shutdown'},
    );
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    _ok(await rpc.call('device_install_app', {'path': '/tmp/app.apk'}));
    // -r so the loop does not wipe the state it just set up, -t so an ordinary
    // debug build is not refused with INSTALL_FAILED_TEST_ONLY.
    expect(
      host.commandLines,
      contains('$_adbPath -s emulator-5554 install -r -t /tmp/app.apk'),
    );
  });

  test('adb install that exits 0 saying Failure is still a failure', () async {
    final host = _Host(
      androidSerials: ['emulator-5554'],
      simulatorStates: {'UDID-16': 'Shutdown'},
    )..installFailsQuietly = true;
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    final error = _error(
      await rpc.call('device_install_app', {'path': '/tmp/app.apk'}),
    );
    expect(error, contains('INSTALL_FAILED_TEST_ONLY'));
  });

  test('device_launch_app starts a named activity on Android', () async {
    final host = _Host(
      androidSerials: ['emulator-5554'],
      simulatorStates: {'UDID-16': 'Shutdown'},
    );
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    _ok(
      await rpc.call('device_launch_app', {
        'appId': 'com.example.app',
        'activity': '.MainActivity',
      }),
    );
    expect(
      host.commandLines,
      contains(
        '$_adbPath -s emulator-5554 shell am start -n '
        'com.example.app/.MainActivity',
      ),
    );
  });

  test('am start that exits 0 saying Error is still a failure', () async {
    final host = _Host(
      androidSerials: ['emulator-5554'],
      simulatorStates: {'UDID-16': 'Shutdown'},
    )..amStartOutput = 'Error: Activity class {…} does not exist.';
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    final error = _error(
      await rpc.call('device_launch_app', {
        'appId': 'com.example.app',
        'activity': '.Missing',
      }),
    );
    expect(error, contains('does not exist'));
  });

  test('activity is refused on a simulator rather than ignored', () async {
    final host = _Host();
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    final error = _error(
      await rpc.call('device_launch_app', {
        'appId': 'com.example.Probe',
        'activity': '.MainActivity',
      }),
    );
    expect(error, contains('one entry point'));
    expect(
      host.commandLines.any((line) => line.contains('simctl launch')),
      isFalse,
      reason: 'a refused argument must not have launched anything',
    );
  });

  test('terminate reaches the right tool on each platform', () async {
    final host = _Host(androidSerials: ['emulator-5554']);
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    _ok(
      await rpc.call('device_terminate_app', {
        'serial': 'emulator-5554',
        'appId': 'com.example.app',
      }),
    );
    _ok(
      await rpc.call('device_terminate_app', {
        'serial': 'UDID-17PRO',
        'appId': 'com.example.Probe',
      }),
    );
    expect(
      host.commandLines,
      containsAll(<String>[
        '$_adbPath -s emulator-5554 shell am force-stop com.example.app',
        'xcrun simctl terminate UDID-17PRO com.example.Probe',
      ]),
    );
  });
}

void _lifecycleTests() {
  test('device_boot starts a simulator by name and waits for it', () async {
    final host = _Host(simulatorStates: {'UDID-16': 'Shutdown'});
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    final result = _ok(await rpc.call('device_boot', {'name': 'iPhone 16'}));
    expect(result['booted'], isTrue);
    // The id that comes back is the one every other verb wants.
    expect(result['udid'], 'UDID-16');
    // `bootstatus -b`, not `boot`: `simctl boot` returns while the device is
    // still starting, and a caller that acted on that would be refused.
    expect(host.commandLines, contains('xcrun simctl bootstatus UDID-16 -b'));
  });

  test('booting something already booted is success, not an error', () async {
    final host = _Host();
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    final result = _ok(await rpc.call('device_boot', {'name': 'UDID-17PRO'}));
    expect(result['booted'], isTrue);
    expect(result['note'], contains('already booted'));
    expect(
      host.commandLines.any((line) => line.contains('bootstatus')),
      isFalse,
    );
  });

  test('device_boot on an unknown name lists what is bootable', () async {
    final host = _Host();
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    final error = _error(await rpc.call('device_boot', {'name': 'iPhone 99'}));
    expect(error, contains('Nothing bootable is called "iPhone 99"'));
    expect(error, contains('iPhone 16'));
  });

  test('device_stop_emulator shuts a simulator down', () async {
    final host = _Host();
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    final result = _ok(
      await rpc.call('device_stop_emulator', {'serial': 'UDID-17PRO'}),
    );
    expect(result['stopped'], isTrue);
    expect(result['note'], contains('not erased'));
    expect(host.commandLines, contains('xcrun simctl shutdown UDID-17PRO'));
  });

  test('device_stop_emulator still kills an AVD', () async {
    final host = _Host(
      androidSerials: ['emulator-5554'],
      simulatorStates: {'UDID-16': 'Shutdown'},
    );
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    // `emu kill` answers OK before the process has finished exiting, so
    // stopEmulator polls the device list rather than trusting the
    // acknowledgement; this host drops the serial when it is killed.
    final result = _ok(
      await rpc.call('device_stop_emulator', {'serial': 'emulator-5554'}),
    );
    expect(host.commandLines, contains('$_adbPath -s emulator-5554 emu kill'));
    expect(result['stopped'], isTrue);
    expect(result['note'], contains('snapshot'));
  });

  test('stopping a simulator that is already down is not an error', () async {
    final host = _Host();
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    final result = _ok(
      await rpc.call('device_stop_emulator', {'serial': 'UDID-16'}),
    );
    expect(result['stopped'], isTrue);
    expect(result['note'], contains('already shut down'));
  });

  test('an emulator can be stopped by AVD name, and again after', () async {
    // The serial is assigned at boot and vanishes with the process, so the
    // handle that worked once cannot be asked about twice. The AVD name is the
    // one that survives — and is what device_boot already takes.
    final host = _Host(
      androidSerials: ['emulator-5554'],
      simulatorStates: {'UDID-16': 'Shutdown'},
    );
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    final stopped = _ok(
      await rpc.call('device_stop_emulator', {'serial': 'Pixel_8_Pro_API_34'}),
    );
    expect(stopped['stopped'], isTrue);
    expect(host.commandLines, contains('$_adbPath -s emulator-5554 emu kill'));

    final again = _ok(
      await rpc.call('device_stop_emulator', {'serial': 'Pixel_8_Pro_API_34'}),
    );
    expect(again['stopped'], isTrue);
    expect(again['note'], contains('already stopped'));
  });

  test(
    'a serial that stopped explains why it no longer names anything',
    () async {
      final host = _Host(simulatorStates: {'UDID-16': 'Shutdown'});
      final rpc = await _server(host);
      addTearDown(rpc.dispose);

      final error = _error(
        await rpc.call('device_stop_emulator', {'serial': 'emulator-5554'}),
      );
      expect(error, contains('keeps no serial'));
      expect(error, contains('Pixel_8_Pro_API_34'));
    },
  );

  test('device_stop_emulator never guesses which device to stop', () async {
    final host = _Host();
    final rpc = await _server(host);
    addTearDown(rpc.dispose);

    expect(
      _error(await rpc.call('device_stop_emulator')),
      contains('serial is required'),
    );
  });
}

/// **What `list_devices` costs the machine it runs on.**
///
/// Measured on this Mac while profiling a running build: `xcrun simctl list
/// devices` is 214ms, `adb devices` 41ms and `emulator -list-avds` 62ms. Asked
/// one after another that is 317ms of waiting for three answers that do not
/// depend on each other; asked together it is as slow as the slowest.
///
/// Counted rather than timed, for the reason every other cost test here gives:
/// the suite runs at `--concurrency=4`, where a wall-clock assertion over a few
/// hundred milliseconds is a coin toss, while overlapping commands are exactly
/// countable.
void _costTests() {
  test('the three probes are asked together, not one after another', () async {
    final host = _Host();
    final s = await _server(host, measureConcurrency: true);
    addTearDown(s.dispose);

    _ok(await s.call('list_devices'));

    final runner = s.runner as _ConcurrencyRunner;
    expect(
      runner.peak,
      greaterThan(1),
      reason: 'adb, simctl and the AVD list do not depend on each other',
    );
  });

  test('resolving a device with no id asks both platforms at once', () async {
    final host = _Host();
    final s = await _server(host, measureConcurrency: true);
    addTearDown(s.dispose);

    // Every `device_*` call that does not name a device comes through
    // `DeviceFleet.all()`, and the fleet is rebuilt per operation on purpose —
    // "who is plugged in right now" is meant to be perishable. So a serial
    // resolution added `adb devices` to `simctl list devices` on every tap,
    // keystroke and screenshot of a driving session, not once per session.
    _ok(await s.call('device_screenshot', {'id': 'emulator-5554'}));
    final resolving = (s.runner as _ConcurrencyRunner).peak;

    expect(resolving, greaterThan(1));
  });

  test('one screen size per ready device, all at once', () async {
    final host = _Host()
      ..androidSerials.addAll(['emulator-5556', 'emulator-5558']);
    final s = await _server(host, measureConcurrency: true);
    addTearDown(s.dispose);

    _ok(await s.call('list_devices'));

    // `wm size` was awaited inside the list literal that built the answer, so
    // three ready devices paid three round trips end to end for a question
    // nobody had ordered.
    final sizes = host.commandLines.where((c) => c.contains('wm size')).length;
    expect(sizes, host.androidSerials.length);
    expect(
      (s.runner as _ConcurrencyRunner).peak,
      greaterThanOrEqualTo(host.androidSerials.length),
      reason: 'every ready device is asked at the same time',
    );
  });

  test('and one per running simulator, the same way', () async {
    // The iOS branch of the same listing did not get the fix its Android twin
    // did, two blocks above it in the same function: `simctl io <udid>
    // enumerate` was awaited inside the list literal, one round trip at a time.
    final host = _Host(
      simulatorStates: {'UDID-17PRO': 'Booted', 'UDID-16': 'Booted'},
    );
    final s = await _server(host, measureConcurrency: true);
    addTearDown(s.dispose);

    _ok(await s.call('list_devices'));

    final enumerates = host.commandLines
        .where((c) => c.contains('io ') && c.contains('enumerate'))
        .length;
    expect(enumerates, 2, reason: 'one per running simulator');
    expect((s.runner as _ConcurrencyRunner).peak, greaterThan(1));
  });
}
