import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:karmashala_devices/pane.dart';
import 'package:karmashala_devices/ports.dart';
import 'package:karmashala_devices/providers.dart';
import 'package:karmashala_devices/src/presentation/device_toolbar_model.dart';
import 'package:karmashala_media/media.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import 'support/fake_command_runner.dart';
import 'support/fakes.dart';

/// **One glyph, one meaning, across the device pane.**
///
/// Before: Home and Record were circles, play/stop in circles meant Launch app
/// *and* logcat *and* the live view, power meant both "shut the emulator down"
/// and "lock the simulator", and trash meant both "delete a file" and "clear
/// the log view". Icon-only, none of those could be told apart.
const _emulator = 'emulator-5554';

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
  model: 'Pixel',
);

const _phone = AndroidDevice(
  serial: 'F6IZLV6LMFT4U4ZT',
  environmentId: 'windows',
  state: DeviceConnectionState.device,
  model: 'Pixel 8',
);

class _Recorder extends DeviceRecordingController {
  _Recorder(this.initial);
  final DeviceRecordingState initial;

  @override
  DeviceRecordingState build() => initial;
}

Future<void> _pump(
  WidgetTester tester, {
  List<AndroidDevice> devices = const [_emulatorDevice],
  DeviceRecordingState recording = const DeviceRecordingIdle(),
  Size size = const Size(1440, 1000),
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final runner = FakeCommandRunner(processFactory: (_) => FakeProcessHandle());
  await tester.pumpWidget(
    ProviderScope(
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
        avdsProvider.overrideWith((ref) async => const []),
        deviceScreenSizeProvider.overrideWith((ref, serial) async => null),
        hostCanRunSimulatorsProvider.overrideWithValue(false),
        iosSimulatorsProvider.overrideWith((ref) async => const []),
        simulatorBackendProvider.overrideWithValue(null),
        deviceVideoSupportProvider.overrideWithValue(
          const VideoSupport.available('pinned for these cases'),
        ),
        deviceRecordingProvider.overrideWith(() => _Recorder(recording)),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(body: DevicePane()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

IconButton _button(WidgetTester tester, String key) =>
    tester.widget<IconButton>(find.byKey(Key(key)));

IconData _glyph(WidgetTester tester, String key) => tester
    .widget<Icon>(
      find.descendant(of: find.byKey(Key(key)), matching: find.byType(Icon)),
    )
    .icon!;

/// Every icon-bearing button on screen, as glyph → the actions it names.
Map<IconData, Set<String>> _actionsByGlyph(WidgetTester tester) {
  final byGlyph = <IconData, Set<String>>{};
  void add(Finder button, String action) {
    final icons = find.descendant(of: button, matching: find.byType(Icon));
    if (icons.evaluate().isEmpty) return;
    final glyph = tester.widget<Icon>(icons.first).icon!;
    byGlyph.putIfAbsent(glyph, () => {}).add(action);
  }

  for (final element in find.byType(IconButton).evaluate()) {
    final button = element.widget as IconButton;
    add(find.byWidget(button), button.tooltip ?? '<no tooltip>');
  }
  for (final element in find.byType(TextButton).evaluate()) {
    final texts = find.descendant(
      of: find.byWidget(element.widget),
      matching: find.byType(Text),
    );
    if (texts.evaluate().isEmpty) continue;
    add(
      find.byWidget(element.widget),
      tester.widget<Text>(texts.first).data ?? '',
    );
  }
  return byGlyph;
}

void main() {
  group('the Android control row', () {
    testWidgets('names each action with its own glyph', (tester) async {
      await _pump(tester);

      expect(_glyph(tester, 'android-back'), AppIcons.arrowUDownLeft);
      expect(_glyph(tester, 'android-home'), AppIcons.house);
      expect(_glyph(tester, 'android-recents'), AppIcons.squaresFour);
      expect(_glyph(tester, 'android-appearance'), AppIcons.moon);
      expect(_glyph(tester, 'android-screenshot'), AppIcons.camera);
      expect(_glyph(tester, 'android-record'), AppIcons.record);
      expect(_glyph(tester, 'android-record-ts'), AppIcons.fileVideo);
      expect(
        _glyph(tester, 'android-clipboard-to-device'),
        AppIcons.uploadSimple,
      );
      expect(
        _glyph(tester, 'android-clipboard-from-device'),
        AppIcons.downloadSimple,
      );
    });

    testWidgets('idle: Record is the record glyph, not selected', (
      tester,
    ) async {
      await _pump(tester);

      final record = _button(tester, 'android-record');
      expect(_glyph(tester, 'android-record'), AppIcons.record);
      expect(record.isSelected, isFalse);
      // No live view in these cases, so it says what it is waiting for.
      expect(record.tooltip, 'Start the live view to record the screen');
      expect(_button(tester, 'android-appearance').isSelected, isFalse);
    });

    testWidgets('recording: a stop square, selected, with the elapsed time', (
      tester,
    ) async {
      await _pump(
        tester,
        recording: DeviceRecordingActive(
          target: AndroidTarget(_emulatorDevice),
          path: '/rec/a.mp4',
          startedAt: testTime.subtract(const Duration(seconds: 42)),
        ),
      );

      final record = _button(tester, 'android-record');
      expect(_glyph(tester, 'android-record'), AppIcons.stopFill);
      expect(record.tooltip, 'Stop recording (00:42)');
      expect(record.isSelected, isTrue);
      expect(record.onPressed, isNotNull);
      // The selected state layer, from the token — not a raw accent alpha.
      final scheme = Theme.of(
        tester.element(find.byKey(const Key('android-record'))),
      ).colorScheme;
      expect(
        record.style!.backgroundColor!.resolve({WidgetState.selected}),
        StateLayers.selected(scheme),
      );
      expect(record.style!.backgroundColor!.resolve({}), isNull);
      // A second "start" beside a running recording would be a lie.
      expect(find.byKey(const Key('android-record-ts')), findsNothing);
    });

    testWidgets('paused: Stop says nothing is being captured', (tester) async {
      await _pump(
        tester,
        recording: DeviceRecordingActive(
          target: AndroidTarget(_emulatorDevice),
          path: '/rec/a.mp4',
          startedAt: testTime.subtract(const Duration(minutes: 3, seconds: 7)),
          receiving: false,
        ),
      );

      expect(_glyph(tester, 'android-record'), AppIcons.stopFill);
      expect(
        _button(tester, 'android-record').tooltip,
        'Stop recording (03:07, paused)',
      );
    });

    testWidgets('stopped again: back to the record glyph', (tester) async {
      // What a stopped recording leaves: an idle state with an outcome.
      await _pump(
        tester,
        recording: const DeviceRecordingIdle(
          DeviceRecordingOutcome(
            deviceId: _emulator,
            result: DeviceRecordingResult.saved,
            message: 'Saved.',
            path: '/rec/a.mp4',
          ),
        ),
      );

      expect(_glyph(tester, 'android-record'), AppIcons.record);
      expect(_button(tester, 'android-record').isSelected, isFalse);
    });
  });

  group('the toolbar', () {
    testWidgets('a running emulator offers to shut down with power', (
      tester,
    ) async {
      await _pump(tester);
      // The toolbar's: the emulator's row in the list offers the same Stop.
      final power = find.descendant(
        of: find.byWidgetPredicate(
          (widget) => widget.runtimeType.toString() == '_DeviceToolbar',
        ),
        matching: find.byTooltip('Stop Pixel'),
      );
      expect(power, findsOneWidget);
      expect(
        find.descendant(of: power, matching: find.byIcon(AppIcons.power)),
        findsOneWidget,
      );
    });

    testWidgets('with no emulator, power is nowhere in the pane', (
      tester,
    ) async {
      await _pump(tester, devices: const [_phone]);
      expect(find.byIcon(AppIcons.power), findsNothing);
    });

    testWidgets('the live view is an eye, not play', (tester) async {
      await _pump(tester);
      expect(find.widgetWithIcon(TextButton, AppIcons.eye), findsOneWidget);
      expect(find.byIcon(AppIcons.play), findsNothing);
      expect(find.byIcon(AppIcons.stop), findsNothing);
    });

    testWidgets('compact, the eye is named in full by its tooltip', (
      tester,
    ) async {
      await _pump(tester, size: const Size(320, 700));
      final button = find.byTooltip('Start live view');
      expect(button, findsOneWidget);
      expect(
        find.descendant(of: button, matching: find.byIcon(AppIcons.eye)),
        findsOneWidget,
      );
    });

    test('Stop and Start say what they stop and start', () {
      expect(PrimaryStreamKind.stopAndroid.tooltip, 'Stop live view');
      expect(PrimaryStreamKind.stopSimulator.tooltip, 'Stop live view');
      expect(PrimaryStreamKind.startAndroid.tooltip, 'Start live view');
    });
  });

  testWidgets('no glyph in the pane names two different actions', (
    tester,
  ) async {
    await _pump(tester);
    // Open the log, so its controls are on screen with the app controls.
    await tester.tap(find.textContaining('Logcat — '));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Pause logcat'), findsOneWidget);

    final byGlyph = _actionsByGlyph(tester);
    final clashes = {
      for (final entry in byGlyph.entries)
        if (entry.value.length > 1)
          'U+${entry.key.codePoint.toRadixString(16)} '
                  '${entry.key.fontFamily}':
              entry.value,
    };
    expect(clashes, isEmpty);
    // And the ones that used to clash are really there to be compared.
    expect(
      byGlyph.keys,
      containsAll([
        AppIcons.house,
        AppIcons.record,
        AppIcons.rocketLaunch,
        AppIcons.prohibit,
        AppIcons.pause,
        AppIcons.broom,
        AppIcons.power,
        AppIcons.eye,
      ]),
    );
  });
}
