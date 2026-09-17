import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:karmashala_devices/pane.dart';
import 'package:karmashala_devices/ports.dart';
import 'package:karmashala_devices/providers.dart';
import 'package:karmashala_devices/widgets.dart';
import 'package:karmashala_media/media.dart';
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
      // Available, so the second record button ("Record .ts") is drawn.
      deviceVideoSupportProvider.overrideWithValue(
        const VideoSupport.available('pinned for these cases'),
      ),
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
          expect(
            find.byTooltip('Start live view').hitTestable(),
            findsOneWidget,
          );
        });
      }
    }
  });

  group('the picture with the log open', () {
    for (final width in [240.0, 360.0]) {
      for (final scale in [1.0, 1.25]) {
        testWidgets('keeps its share at ${width.toInt()}x478, ${scale}x text', (
          tester,
        ) async {
          final container = await _pump(
            tester,
            size: Size(width, 478),
            textScale: scale,
            avds: const [
              Avd(name: 'Pixel_7', runningSerial: _emulator),
              Avd(name: 'Pixel_Tablet'),
            ],
          );
          container
              .read(selectedDeviceSerialProvider.notifier)
              .select(_emulator);
          await tester.pumpAndSettle();
          container.read(deviceLogcatOpenProvider.notifier).toggle();
          await tester.pumpAndSettle();

          // The log really is open, under a picture region that is still one.
          expect(find.textContaining('no line yet'), findsOneWidget);
          // `_LiveView` is the picture's region whether or not a stream is up:
          // the pane hands it everything the controls and the log do not take.
          // Fixed-height controls, app controls and a 220px log above it once
          // left 64px — a 30px-wide phone at 240px.
          final picture = find.byWidgetPredicate(
            (widget) => widget.runtimeType.toString() == '_LiveView',
          );
          expect(picture, findsOneWidget);
          expect(tester.getSize(picture).height, greaterThanOrEqualTo(160));
        });
      }
    }
  });

  group('a device row with three actions', () {
    for (final width in [240.0, 320.0, 400.0]) {
      for (final scale in scales) {
        testWidgets('keeps its name and every action at ${width.toInt()}px, '
            '${scale}x text', (tester) async {
          // Tall enough that the list is not what is being measured.
          await _pump(tester, size: Size(width, 900), textScale: scale);

          // The emulator's row: Live preview, Files and Stop. As a ListTile
          // with a Row of buttons trailing it, the name was squeezed to a
          // few pixels, then the tile threw and no row was laid out at all.
          final name = find.text('sdk_gphone64_arm64');
          expect(name, findsOneWidget);
          expect(
            tester.getSize(name).width,
            greaterThanOrEqualTo(width * 0.6),
            reason: 'the name is the row; it must keep most of the width',
          );

          for (final key in [
            'preview-$_emulator',
            'files-$_emulator',
            'stop-emulator-$_emulator',
            'preview-$_phoneSerial',
            'files-$_phoneSerial',
          ]) {
            final action = find.byKey(Key(key));
            await tester.ensureVisible(action);
            await tester.pumpAndSettle();
            expect(
              action.hitTestable(),
              findsOneWidget,
              reason: '$key must be reachable',
            );
            final rect = tester.getRect(action);
            expect(rect.left, greaterThanOrEqualTo(0), reason: key);
            expect(rect.right, lessThanOrEqualTo(width), reason: key);
          }
        });
      }
    }
  });

  testWidgets('Home and the two record buttons each have their own glyph', (
    tester,
  ) async {
    // Home, Record and Record .ts were all a plain circle, icon-only, with
    // Home beside Record: nothing told "go home" from "start recording".
    await _pump(
      tester,
      size: const Size(1000, 900),
      textScale: 1.0,
      devices: const [_emulatorDevice],
    );

    IconData glyphOf(String key) => tester
        .widget<Icon>(
          find.descendant(
            of: find.byKey(Key(key)),
            matching: find.byType(Icon),
          ),
        )
        .icon!;
    final home = glyphOf('android-home');
    final record = glyphOf('android-record');
    final recordTs = glyphOf('android-record-ts');
    expect({home, record, recordTs}, hasLength(3));
  });
}
