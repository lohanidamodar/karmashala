import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:karmashala_devices/pane.dart';
import 'package:karmashala_devices/ports.dart';
import 'package:karmashala_devices/providers.dart';
import 'package:karmashala_ui/theme.dart';

import 'support/fake_command_runner.dart';
import 'support/fakes.dart';

/// **The pane at the sizes a side panel actually is.** 240–360px wide and
/// about 478px tall at the window's minimum, with the text scaled up — where
/// device rows lost their names and the picture collapsed to a sliver.
///
/// Every case runs with the suite's square test font, which is wider than any
/// real one: a layout that holds here holds with a proportional face.
const _emulator = 'emulator-5554';
const _phoneSerial = 'F6IZLV6LMFT4U4ZT';

const _sdk = AndroidSdk(
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

const _emulatorDevice = AndroidDevice(
  serial: _emulator,
  environmentId: 'windows',
  state: DeviceConnectionState.device,
  model: 'sdk_gphone64_arm64',
);

const _phone = AndroidDevice(
  serial: _phoneSerial,
  environmentId: 'windows',
  state: DeviceConnectionState.device,
  model: 'Pixel 8',
);

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required Size size,
  required double textScale,
  List<Avd> avds = const [],
  List<AndroidDevice> devices = const [_emulatorDevice, _phone],
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final runner = FakeCommandRunner(
    // `logcat` is started when the log is opened and never says anything.
    processFactory: (_) => FakeProcessHandle(),
  );
  final container = ProviderContainer(
    overrides: [
      deviceCommandRunnerFactoryProvider.overrideWithValue(
        FakeCommandRunnerFactory(fallback: runner),
      ),
      deviceClockProvider.overrideWithValue(FixedClock(testTime)),
      androidSdkProvider.overrideWith((ref) async => _sdk),
      androidEmulatorArgumentsProvider.overrideWithValue(const []),
      androidSlimmingServiceProvider.overrideWithValue(null),
      slimmingOnStartProvider.overrideWithValue(false),
      slimmingKeptCategoriesProvider.overrideWithValue(const {}),
      devicesProvider.overrideWith((ref) async => devices),
      avdsProvider.overrideWith((ref) async => avds),
      deviceScreenSizeProvider.overrideWith((ref, serial) async => null),
      hostCanRunSimulatorsProvider.overrideWithValue(false),
      iosSimulatorsProvider.overrideWith((ref) async => const []),
      simulatorBackendProvider.overrideWithValue(null),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(body: DevicePane()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  const scales = [1.0, 1.25, 1.3];

  group('the toolbar', () {
    for (final width in [240.0, 320.0]) {
      for (final scale in scales) {
        testWidgets('leaves the picker room at ${width.toInt()}px, ${scale}x '
            'text', (tester) async {
          // No device: nothing but the toolbar and a message is on screen.
          // "Live view" as a labelled button beside Pair and Refresh left the
          // picker 0px wide, and its row overflowed.
          await _pump(
            tester,
            size: Size(width, 478),
            textScale: scale,
            devices: const [],
          );

          final picker = find.byType(DropdownButton<String>);
          expect(tester.getSize(picker).width, greaterThanOrEqualTo(48));
          // The action is still there, named by its tooltip.
          expect(find.byTooltip('Live view').hitTestable(), findsOneWidget);
        });
      }
    }
  });
}
