import 'package:chitragupta/src/features/devices/application/device_providers.dart';
import 'package:chitragupta/src/features/devices/domain/android_device.dart';
import 'package:chitragupta/src/features/devices/presentation/device_pane.dart';
import 'package:chitragupta/src/features/environments/domain/environment_kind.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _phone = Size(390, 844);
const _desktop = Size(1440, 900);

AndroidSdk _sdk() => const AndroidSdk(
  root: EnvironmentPath(environmentId: 'windows', path: r'C:\sdk'),
  adb: EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\sdk\platform-tools\adb.exe',
  ),
);

AndroidDevice _device({
  String serial = 'emulator-5554',
  DeviceConnectionState state = DeviceConnectionState.device,
}) => AndroidDevice(
  serial: serial,
  environmentId: 'windows',
  state: state,
  model: 'Pixel',
);

Future<void> _pump(
  WidgetTester tester, {
  required AndroidSdk? sdk,
  required List<AndroidDevice> devices,
  List<Avd> avds = const [],
  Size size = _desktop,
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        androidSdkProvider.overrideWith((ref) async => sdk),
        devicesProvider.overrideWith((ref) async => devices),
        avdsProvider.overrideWith((ref) async => avds),
        selectedDeviceScreenSizeProvider.overrideWith((ref) async => null),
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
}
