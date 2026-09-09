import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/app/shell/reveal_in_file_manager.dart';
import 'package:karmashala/src/features/devices/application/device_providers.dart';
import 'package:karmashala/src/features/devices/application/device_recording_controller.dart';
import 'package:karmashala/src/features/devices/application/ios_device_providers.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:karmashala/src/features/devices/presentation/device_pane.dart';

import '../../support/fake_command_runner.dart';

/// The pane's rendered widget tree, frozen for its main states.
///
/// `device_pane.dart` composes a dozen private widgets, and every ordinary test
/// here asserts one thing at a time — a label, a tap, a count. None of them
/// would notice a family arriving at a different depth, a `Divider` lost on the
/// way across, or a branch that used to be entered no longer being entered.
/// Splitting the file is meant to change none of that.
///
/// So the whole tree is committed: every element under [DevicePane], with its
/// widget type, its key, and the text or tooltip it carries. A refactor that
/// does not touch behaviour leaves this file alone; a change that does touch it
/// has to be made deliberately, and the diff says exactly what a user will see
/// differently.
///
/// What it cannot reach: the live picture. `_LiveView`'s non-null branch needs
/// a real media_kit `VideoController`, which needs libmpv, so the states below
/// enter `_LiveView` and stop at its "no picture yet" fallback. The same holds
/// for the touch and keyboard surfaces under it, which have their own tests.
///
/// Regenerate only when the change is intended, and never as a side effect of
/// `--update-goldens` (which is why this is its own variable):
///
/// ```
/// KARMASHALA_WRITE_DEVICE_PANE_GOLDEN=1 flutter test \
///   test/features/devices/device_pane_tree_golden_test.dart
/// ```
const _goldenPath = 'test/features/devices/device_pane_tree.golden.txt';

const _emulator = 'emulator-5554';
const _phoneSerial = 'F6IZLV6LMFT4U4ZT';
const _desktop = Size(1440, 900);

AndroidSdk _sdk() => const AndroidSdk(
  root: EnvironmentPath(environmentId: 'windows', path: r'C:\sdk'),
  adb: EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\sdk\platform-tools\adb.exe',
  ),
  emulator: EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\sdk\emulator\emulator.exe',
  ),
);

AndroidDevice _device({
  String serial = _emulator,
  DeviceConnectionState state = DeviceConnectionState.device,
  String model = 'Pixel',
}) => AndroidDevice(
  serial: serial,
  environmentId: 'windows',
  state: state,
  model: model,
);

IosSimulator _bootedSimulator(String udid, String name) => IosSimulator(
  udid: udid,
  name: name,
  state: SimulatorState.booted,
  runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-26-4',
  deviceTypeIdentifier: 'com.apple.CoreSimulator.SimDeviceType.iPhone-17',
  isAvailable: true,
);

class _StubSimulatorBackend implements WdaBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('these cases never start a live view');
}

/// A recorder whose state the golden sets directly, the way the banner's own
/// test does.
class _StubRecorder extends DeviceRecordingController {
  _StubRecorder(this.initial);

  final DeviceRecordingState initial;

  @override
  DeviceRecordingState build() => initial;
}

Future<void> _pump(
  WidgetTester tester, {
  required AndroidSdk? sdk,
  required List<AndroidDevice> devices,
  List<Avd> avds = const [],
  List<IosSimulator> simulators = const [],
  bool simulatorBackend = false,
  DeviceRecordingState recording = const DeviceRecordingIdle(),
}) async {
  tester.view
    ..physicalSize = _desktop
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // Nothing here may reach a real process: the pane's controls resolve a
        // runner as soon as a ready device exists.
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
        ),
        androidSdkProvider.overrideWith((ref) => Future.value(sdk)),
        androidEmulatorArgumentsProvider.overrideWithValue(const []),
        androidSlimmingServiceProvider.overrideWithValue(null),
        slimmingOnStartProvider.overrideWithValue(false),
        slimmingKeptCategoriesProvider.overrideWithValue(const {}),
        devicesProvider.overrideWith((ref) async => devices),
        avdsProvider.overrideWith((ref) async => avds),
        deviceScreenSizeProvider.overrideWith((ref, serial) async => null),
        hostCanRunSimulatorsProvider.overrideWithValue(simulators.isNotEmpty),
        iosSimulatorsProvider.overrideWith((ref) async => simulators),
        simulatorBackendProvider.overrideWithValue(
          simulatorBackend ? _StubSimulatorBackend() : null,
        ),
        deviceRecordingProvider.overrideWith(() => _StubRecorder(recording)),
        // Pinned to Windows so "can this path be shown" is the same answer on
        // every host the suite runs on.
        revealInFileManagerProvider.overrideWithValue(
          RevealInFileManager(
            host: FakeCommandRunner(),
            translator: const PathTranslator(),
            environmentFor: (_) => windowsHostEnvironment(DateTime.utc(2026)),
            fileManagerOverride: HostFileManager.windowsExplorer,
          ),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: DevicePane())),
    ),
  );
  await tester.pumpAndSettle();
}

/// Object hashes are per-run. A key or a type that carries one is normalised so
/// the golden is about the shape, not about this process's addresses.
final _hash = RegExp(r'#[0-9a-f]{5}');

String _describe(Widget widget) {
  final buffer = StringBuffer(widget.runtimeType.toString());
  if (widget.key case final key?) buffer.write(' key=$key');
  switch (widget) {
    case Text(:final data?):
      buffer.write(' text=${_oneLine(data)}');
    case Tooltip(:final message?):
      buffer.write(' tooltip=${_oneLine(message)}');
    case _:
      break;
  }
  return buffer.toString().replaceAll(_hash, '#…');
}

/// One line, whatever the string contains.
String _oneLine(String value) =>
    '"${value.replaceAll('\\', r'\\').replaceAll('\n', r'\n').replaceAll('"', r'\"')}"';

String _tree(WidgetTester tester) {
  final buffer = StringBuffer();
  void walk(Element element, int depth) {
    buffer
      ..write('  ' * depth)
      ..writeln(_describe(element.widget));
    element.visitChildren((child) => walk(child, depth + 1));
  }

  walk(tester.element(find.byType(DevicePane)), 0);
  return buffer.toString();
}

void main() {
  final captured = <String, String>{};

  Future<void> capture(
    WidgetTester tester,
    String state, {
    required AndroidSdk? sdk,
    required List<AndroidDevice> devices,
    List<Avd> avds = const [],
    List<IosSimulator> simulators = const [],
    bool simulatorBackend = false,
    DeviceRecordingState recording = const DeviceRecordingIdle(),
  }) async {
    await _pump(
      tester,
      sdk: sdk,
      devices: devices,
      avds: avds,
      simulators: simulators,
      simulatorBackend: simulatorBackend,
      recording: recording,
    );
    captured[state] = _tree(tester);
  }

  testWidgets('no SDK', (tester) async {
    await capture(tester, 'no SDK', sdk: null, devices: const []);
  });

  testWidgets('an SDK and no device', (tester) async {
    await capture(tester, 'an SDK and no device', sdk: _sdk(), devices: const []);
  });

  testWidgets('an AVD that could be booted', (tester) async {
    await capture(
      tester,
      'an AVD that could be booted',
      sdk: _sdk(),
      devices: const [],
      avds: const [Avd(name: 'Pixel_7')],
    );
  });

  testWidgets('a booted emulator', (tester) async {
    await capture(
      tester,
      'a booted emulator',
      sdk: _sdk(),
      devices: [_device()],
      avds: const [Avd(name: 'Pixel_7')],
    );
  });

  testWidgets('a phone', (tester) async {
    await capture(
      tester,
      'a phone',
      sdk: _sdk(),
      devices: [_device(serial: _phoneSerial, model: 'Pixel 8')],
    );
  });

  testWidgets('an unauthorized device', (tester) async {
    await capture(
      tester,
      'an unauthorized device',
      sdk: _sdk(),
      devices: [
        _device(
          serial: _phoneSerial,
          state: DeviceConnectionState.unauthorized,
        ),
      ],
    );
  });

  testWidgets('a booted simulator beside a phone', (tester) async {
    await capture(
      tester,
      'a booted simulator beside a phone',
      sdk: _sdk(),
      devices: [_device(serial: _phoneSerial, model: 'Pixel 8')],
      simulators: [_bootedSimulator('UDID-1', 'iPhone 17')],
      simulatorBackend: true,
    );
  });

  testWidgets('recording on', (tester) async {
    await capture(
      tester,
      'recording on',
      sdk: _sdk(),
      devices: [_device()],
      recording: DeviceRecordingActive(
        target: AndroidTarget(_device()),
        path: r'C:\data\recordings\emulator-5554-20260908-140307.ts',
        startedAt: DateTime.utc(2026, 9, 8, 14, 3, 7),
      ),
    );
  });

  // Declared last so every state above has been captured by the time it runs.
  test('the pane renders the committed tree', () {
    final encoded = StringBuffer(
      '# The device pane\'s rendered widget tree, per state.\n'
      '# Regenerate with KARMASHALA_WRITE_DEVICE_PANE_GOLDEN=1; see\n'
      '# test/features/devices/device_pane_tree_golden_test.dart.\n',
    );
    for (final state in captured.keys.toList()..sort()) {
      encoded
        ..writeln()
        ..writeln('== $state ==')
        ..write(captured[state]);
    }
    final file = File(_goldenPath);
    if (Platform.environment['KARMASHALA_WRITE_DEVICE_PANE_GOLDEN'] == '1') {
      file.writeAsStringSync(encoded.toString());
      // ignore: avoid_print
      print('wrote $_goldenPath');
    }
    expect(
      file.existsSync(),
      isTrue,
      reason: '$_goldenPath is missing; see the header of this file',
    );
    expect(
      encoded.toString(),
      file.readAsStringSync(),
      reason:
          'The pane renders a different tree. If that was intended, regenerate '
          'the golden; if it was a refactor, something moved that should not '
          'have.',
    );
  });
}
