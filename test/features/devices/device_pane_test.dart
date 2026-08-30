import 'package:chitragupta/src/core/process/command_runner_providers.dart';
import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/features/devices/application/device_providers.dart';
import 'package:chitragupta/src/features/devices/domain/android_device.dart';
import 'package:chitragupta/src/features/devices/domain/device_input.dart';
import 'package:chitragupta/src/features/devices/presentation/device_pane.dart';
import 'package:chitragupta/src/features/environments/domain/environment_kind.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';

const _phone = Size(390, 844);
const _desktop = Size(1440, 900);

const _emulator = 'emulator-5554';
const _phoneSerial = 'F6IZLV6LMFT4U4ZT';

AndroidSdk _sdk() => const AndroidSdk(
  root: EnvironmentPath(environmentId: 'windows', path: r'C:\sdk'),
  adb: EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\sdk\platform-tools\adb.exe',
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

Future<void> _pump(
  WidgetTester tester, {
  required AndroidSdk? sdk,
  required List<AndroidDevice> devices,
  List<Avd> avds = const [],
  Map<String, DeviceScreenSize> screens = const {},
  Size size = _desktop,
  FakeCommandRunner? runner,
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (runner != null)
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(fallback: runner),
          ),
        androidSdkProvider.overrideWith((ref) async => sdk),
        devicesProvider.overrideWith((ref) async => devices),
        avdsProvider.overrideWith((ref) async => avds),
        deviceScreenSizeProvider.overrideWith(
          (ref, serial) async => screens[serial],
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: DevicePane())),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('DevicePane empty states', () {
    testWidgets('explains how to install the SDK when none is found', (
      tester,
    ) async {
      await _pump(tester, sdk: null, devices: const []);
      expect(find.textContaining('No Android SDK found'), findsOneWidget);
      expect(find.textContaining('ANDROID_HOME'), findsOneWidget);
    });

    testWidgets('asks for a device when the SDK is present but nothing is '
        'connected', (tester) async {
      await _pump(tester, sdk: _sdk(), devices: const []);
      expect(find.textContaining('No devices connected'), findsOneWidget);
    });

    testWidgets('surfaces an unauthorized device instead of hiding it', (
      tester,
    ) async {
      await _pump(
        tester,
        sdk: _sdk(),
        devices: [_device(state: DeviceConnectionState.unauthorized)],
      );
      expect(
        find.textContaining('accept the USB debugging prompt'),
        findsOneWidget,
      );
    });

    testWidgets('offers to boot an AVD when one exists', (tester) async {
      await _pump(
        tester,
        sdk: _sdk(),
        devices: const [],
        avds: const [Avd(name: 'Pixel_8_Pro')],
      );
      expect(find.text('Pixel_8_Pro'), findsOneWidget);
      expect(find.text('Start'), findsOneWidget);
    });

    testWidgets('prompts to start the live view once a device is ready', (
      tester,
    ) async {
      await _pump(tester, sdk: _sdk(), devices: [_device()]);
      expect(find.textContaining('start the live view'), findsOneWidget);
      expect(find.text('Live view'), findsOneWidget);
    });
  });

  group('DevicePane layout', () {
    testWidgets('renders without overflow at a compact size', (tester) async {
      await _pump(tester, sdk: _sdk(), devices: [_device()], size: _phone);
      expect(tester.takeException(), isNull);
      expect(find.byType(DevicePane), findsOneWidget);
    });

    testWidgets('renders without overflow at a desktop size', (tester) async {
      await _pump(tester, sdk: _sdk(), devices: [_device()], size: _desktop);
      expect(tester.takeException(), isNull);
      expect(find.byType(DevicePane), findsOneWidget);
    });

    testWidgets('the emulator list does not overflow a compact pane', (
      tester,
    ) async {
      await _pump(
        tester,
        sdk: _sdk(),
        devices: [_device()],
        avds: const [
          Avd(name: 'Pixel_8_Pro', runningSerial: _emulator),
          Avd(name: 'Pixel_Tablet'),
          Avd(name: 'Nexus_5'),
          Avd(name: 'Wear_Small'),
        ],
        size: _phone,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('hides the hardware buttons when no device is selected', (
      tester,
    ) async {
      await _pump(tester, sdk: _sdk(), devices: const []);
      expect(find.byTooltip('Back'), findsNothing);
    });

    testWidgets('shows back, home and recents once a device is selected', (
      tester,
    ) async {
      await _pump(tester, sdk: _sdk(), devices: [_device()]);
      expect(find.byTooltip('Back'), findsOneWidget);
      expect(find.byTooltip('Home'), findsOneWidget);
      expect(find.byTooltip('Recents'), findsOneWidget);
    });
  });

  group('deviceUnavailableReason', () {
    test('says nothing while discovery is still running', () {
      expect(
        deviceUnavailableReason(
          sdk: null,
          sdkResolved: false,
          devices: const [],
          kind: EnvironmentKind.windowsNative,
        ),
        isNull,
      );
    });

    test('names the WSL location when the environment is WSL', () {
      final reason = deviceUnavailableReason(
        sdk: null,
        sdkResolved: true,
        devices: const [],
        kind: EnvironmentKind.wsl,
      );
      expect(reason, contains('~/Android/Sdk'));
    });

    test('is null once a ready device exists', () {
      expect(
        deviceUnavailableReason(
          sdk: _sdk(),
          sdkResolved: true,
          devices: [_device()],
          kind: EnvironmentKind.windowsNative,
        ),
        isNull,
      );
    });

    test('reports offline devices distinctly from unauthorized ones', () {
      final reason = deviceUnavailableReason(
        sdk: _sdk(),
        sdkResolved: true,
        devices: [_device(state: DeviceConnectionState.offline)],
        kind: EnvironmentKind.windowsNative,
      );
      expect(reason, contains('offline'));
    });
  });

  group('DevicePane toolbar', () {
    testWidgets('the refresh button says what it actually refreshes', (
      tester,
    ) async {
      // It used to say "Refresh devices", so that is what people pressed when
      // the live view froze — and it refreshed the list, not the stream.
      await _pump(tester, sdk: _sdk(), devices: [_device()]);
      expect(find.byTooltip('Refresh device list'), findsOneWidget);
      expect(find.byTooltip('Refresh devices'), findsNothing);
    });

    testWidgets('offers to stop a selected emulator', (tester) async {
      await _pump(tester, sdk: _sdk(), devices: [_device()]);
      expect(find.byTooltip('Stop emulator'), findsOneWidget);
    });

    testWidgets('does not offer to stop a physical device', (tester) async {
      // `emu kill` talks to the emulator console; on a phone it can only fail,
      // and a control that can only fail should not be there.
      await _pump(
        tester,
        sdk: _sdk(),
        devices: [_device(serial: _phoneSerial)],
      );
      expect(find.byTooltip('Stop emulator'), findsNothing);
      expect(
        find.byKey(const Key('stop-emulator-$_phoneSerial')),
        findsNothing,
      );
    });

    testWidgets(
      'stopping an emulator asks first, and cancelling does nothing',
      (tester) async {
        final runner = FakeCommandRunner();
        await _pump(tester, sdk: _sdk(), devices: [_device()], runner: runner);
        await tester.tap(find.byTooltip('Stop emulator'));
        await tester.pumpAndSettle();
        expect(find.textContaining('is lost'), findsOneWidget);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(
          runner.requests.any((r) => r.arguments.contains('kill')),
          isFalse,
        );
      },
    );
  });

  // Bug 1: "i see an emulator running but cannot stop it in the list without
  // starting live view". The action existed, but only on the live-view toolbar.
  group('DevicePane emulator list', () {
    testWidgets('offers to stop a running emulator with the live view off', (
      tester,
    ) async {
      await _pump(
        tester,
        sdk: _sdk(),
        devices: [_device()],
        avds: const [Avd(name: 'Pixel_8_Pro', runningSerial: _emulator)],
      );
      // Nothing is streaming — the toolbar still offers to *start* the live
      // view — and the row is stoppable anyway. That is the whole fix.
      expect(find.text('Live view'), findsOneWidget);
      expect(find.byKey(const Key('stop-emulator-$_emulator')), findsOneWidget);
      expect(find.text('Start'), findsNothing);
    });

    testWidgets('stopping from the list confirms, then runs emu kill', (
      tester,
    ) async {
      final runner = FakeCommandRunner();
      await _pump(
        tester,
        sdk: _sdk(),
        devices: [_device()],
        avds: const [Avd(name: 'Pixel_8_Pro', runningSerial: _emulator)],
        runner: runner,
      );
      await tester.tap(find.byKey(const Key('stop-emulator-$_emulator')));
      await tester.pumpAndSettle();
      // The confirmation is kept: anything not written to a snapshot is lost.
      expect(find.textContaining('is lost'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Stop emulator'));
      await tester.pumpAndSettle();

      expect(
        runner.requests.map((r) => r.arguments.join(' ')),
        contains('-s $_emulator emu kill'),
      );
    });

    testWidgets('cancelling a stop from the list kills nothing', (
      tester,
    ) async {
      final runner = FakeCommandRunner();
      await _pump(
        tester,
        sdk: _sdk(),
        devices: [_device()],
        avds: const [Avd(name: 'Pixel_8_Pro', runningSerial: _emulator)],
        runner: runner,
      );
      await tester.tap(find.byKey(const Key('stop-emulator-$_emulator')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(runner.requests.any((r) => r.arguments.contains('kill')), isFalse);
    });

    testWidgets('an AVD that is not running offers Start, not Stop', (
      tester,
    ) async {
      await _pump(
        tester,
        sdk: _sdk(),
        devices: const [],
        avds: const [Avd(name: 'Pixel_8_Pro')],
      );
      expect(find.byKey(const Key('start-avd-Pixel_8_Pro')), findsOneWidget);
      expect(find.byKey(const Key('stop-emulator-$_emulator')), findsNothing);
    });

    testWidgets('a running emulator with no AVD row is still stoppable', (
      tester,
    ) async {
      // No emulator package means no AVD list at all, but `adb devices` still
      // shows the emulator and `emu kill` still works on it.
      await _pump(tester, sdk: _sdk(), devices: [_device()]);
      expect(find.byKey(const Key('stop-emulator-$_emulator')), findsOneWidget);
    });

    testWidgets('a running emulator is not listed twice', (tester) async {
      await _pump(
        tester,
        sdk: _sdk(),
        devices: [_device()],
        avds: const [Avd(name: 'Pixel_8_Pro', runningSerial: _emulator)],
      );
      expect(find.byKey(const Key('stop-emulator-$_emulator')), findsOneWidget);
    });

    testWidgets('a physical device never appears in the emulator list', (
      tester,
    ) async {
      await _pump(
        tester,
        sdk: _sdk(),
        devices: [_device(serial: _phoneSerial, model: 'CPH1989')],
      );
      expect(find.text('CPH1989'), findsNothing);
      expect(find.text('Stop'), findsNothing);
    });
  });

  // Bug 3: the adb gesture sink took its coordinate space from the *selected*
  // device's screen size. Once selection and streaming diverged, a tap was
  // mapped through the wrong resolution and landed in the wrong place on the
  // device being watched — while appearing to work.
  group('deviceScreenSizeProvider', () {
    ProviderContainer containerFor(FakeCommandRunner runner) {
      final container = ProviderContainer(
        overrides: [
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(fallback: runner),
          ),
          androidSdkProvider.overrideWith((ref) async => _sdk()),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('reports each device its own screen size, by serial', () async {
      final runner = FakeCommandRunner(
        responder: (request) {
          final args = request.arguments.join(' ');
          if (args == '-s $_emulator shell wm size') {
            return const CommandResult(
              exitCode: 0,
              stdout: 'Physical size: 1080x2400\n',
              stderr: '',
            );
          }
          if (args == '-s $_phoneSerial shell wm size') {
            return const CommandResult(
              exitCode: 0,
              stdout: 'Physical size: 1080x2340\n',
              stderr: '',
            );
          }
          return const CommandResult(exitCode: 1, stdout: '', stderr: '');
        },
      );
      final container = containerFor(runner);
      await container.read(androidSdkProvider.future);

      // The two devices differ by 60 px of height. Asking for one and being
      // given the other's is exactly how a tap lands in the wrong place.
      expect(
        await container.read(deviceScreenSizeProvider(_emulator).future),
        const DeviceScreenSize(width: 1080, height: 2400),
      );
      expect(
        await container.read(deviceScreenSizeProvider(_phoneSerial).future),
        const DeviceScreenSize(width: 1080, height: 2340),
      );
    });

    test('asks the device named, and no other', () async {
      final runner = FakeCommandRunner();
      final container = containerFor(runner);
      await container.read(androidSdkProvider.future);
      await container.read(deviceScreenSizeProvider(_phoneSerial).future);

      expect(runner.requests.map((r) => r.arguments.join(' ')), [
        '-s $_phoneSerial shell wm size',
      ]);
    });

    test('is null when there is no SDK to ask with', () async {
      final container = ProviderContainer(
        overrides: [androidSdkProvider.overrideWith((ref) async => null)],
      );
      addTearDown(container.dispose);
      await container.read(androidSdkProvider.future);
      expect(
        await container.read(deviceScreenSizeProvider(_emulator).future),
        isNull,
      );
    });
  });
}
