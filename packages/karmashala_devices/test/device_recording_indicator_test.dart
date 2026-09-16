import 'package:agent_cli/discovery.dart' as agent_cli;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:karmashala_devices/ports.dart';
import 'package:karmashala_devices/providers.dart';
import 'package:karmashala_devices/widgets.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart' show StatusSpinnerClock;
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import 'support/fakes.dart';

/// **What says "recording" in the device pane.** A plain circle said it
/// before — the same glyph as a radio button and, beside it, Home.
const _serial = 'emulator-5554';

const _device = AndroidDevice(
  serial: _serial,
  environmentId: 'windows',
  state: DeviceConnectionState.device,
  model: 'Pixel',
);

/// A clock the test moves by hand.
class _Clock implements Clock, agent_cli.Clock {
  _Clock(this.now);
  DateTime now;

  @override
  DateTime nowUtc() => now;
}

class _Recorder extends DeviceRecordingController {
  _Recorder(this.initial);
  final DeviceRecordingState initial;

  @override
  DeviceRecordingState build() => initial;
}

DeviceRecordingActive _active({
  Duration ago = const Duration(seconds: 42),
  bool receiving = true,
}) => DeviceRecordingActive(
  target: AndroidTarget(_device),
  path: '/rec/emulator-5554.mp4',
  startedAt: testTime.subtract(ago),
  receiving: receiving,
);

Future<_Clock> _pumpBanner(
  WidgetTester tester,
  DeviceRecordingState state, {
  bool reducedMotion = false,
}) async {
  final clock = _Clock(testTime);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        deviceClockProvider.overrideWithValue(clock),
        deviceRecordingProvider.overrideWith(() => _Recorder(state)),
        devicesProvider.overrideWith((ref) async => const [_device]),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: reducedMotion),
            child: const Scaffold(body: DeviceRecordingBanner()),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return clock;
}

void main() {
  group('formatRecordingElapsed', () {
    test('reads as a clock, hours only once there are some', () {
      expect(formatRecordingElapsed(Duration.zero), '00:00');
      expect(formatRecordingElapsed(const Duration(seconds: 42)), '00:42');
      expect(
        formatRecordingElapsed(const Duration(minutes: 12, seconds: 5)),
        '12:05',
      );
      expect(
        formatRecordingElapsed(
          const Duration(hours: 1, minutes: 2, seconds: 3),
        ),
        '1:02:03',
      );
    });

    test('a clock that stepped back reads zero, not a minus sign', () {
      expect(formatRecordingElapsed(const Duration(seconds: -5)), '00:00');
    });
  });

  test('Stop says the action, how long, and whether it is capturing', () {
    expect(stopRecordingTooltip(_active(), testTime), 'Stop recording (00:42)');
    expect(
      stopRecordingTooltip(_active(receiving: false), testTime),
      'Stop recording (00:42, paused)',
    );
  });

  test('the pulse dims and comes back, never to nothing', () {
    final opacities = [
      for (var step = 0; step < Motion.statusSteps; step++)
        RecordingDot.opacityAt(step),
    ];
    expect(opacities.first, 1.0);
    expect(opacities.reduce((a, b) => a < b ? a : b), RecordingDot.minOpacity);
    expect(opacities.toSet().length, greaterThan(2), reason: 'it moves');
  });

  group('the banner while recording', () {
    testWidgets('a red record dot, the elapsed time, and a stop square', (
      tester,
    ) async {
      await _pumpBanner(tester, _active());

      final dot = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const Key('device-recording-dot')),
          matching: find.byType(Icon),
        ),
      );
      expect(dot.icon, AppIcons.recordFill);
      final failure = SemanticColors.of(
        tester.element(find.byKey(const Key('device-recording-dot'))),
      ).failure;
      expect(dot.color!.withValues(alpha: 1), failure);
      expect(dot.size, Chrome.icon);

      expect(
        tester
            .widget<Text>(find.byKey(const Key('device-recording-elapsed')))
            .data,
        '00:42',
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('device-recording-stop')),
          matching: find.byIcon(AppIcons.stopFill),
        ),
        findsOneWidget,
      );
      expect(find.byIcon(AppIcons.circle), findsNothing);
    });

    testWidgets('the elapsed time moves with the clock', (tester) async {
      final clock = await _pumpBanner(tester, _active());
      clock.now = testTime.add(const Duration(seconds: 18));
      await tester.pump(RecordingClock.tick);
      expect(find.text('01:00'), findsOneWidget);
    });

    testWidgets('the dot pulses on the shared status clock', (tester) async {
      final spinner = StatusSpinnerClock.instance;
      await _pumpBanner(tester, _active());
      expect(spinner.debugSubscriberCount, 1);
      expect(spinner.isRunning, isTrue);

      Color colour() => tester
          .widget<Icon>(
            find.descendant(
              of: find.byKey(const Key('device-recording-dot')),
              matching: find.byType(Icon),
            ),
          )
          .color!;
      final before = colour();
      await tester.pump(Motion.statusPeriod ~/ Motion.statusSteps);
      expect(colour(), isNot(before), reason: 'the opacity stepped');

      await tester.pumpWidget(const SizedBox());
      expect(spinner.isRunning, isFalse, reason: 'no dot, no timer');
    });

    testWidgets('under reduced motion the dot is still and asks for nothing', (
      tester,
    ) async {
      final spinner = StatusSpinnerClock.instance;
      await _pumpBanner(tester, _active(), reducedMotion: true);

      expect(find.byIcon(AppIcons.recordFill), findsOneWidget);
      expect(spinner.debugSubscriberCount, 0);
      expect(spinner.isRunning, isFalse);
      final dot = tester.widget<Icon>(find.byIcon(AppIcons.recordFill));
      expect(dot.color!.a, 1.0);
    });

    testWidgets('paused: a pause glyph, and no dot claiming capture', (
      tester,
    ) async {
      // A pane switch: the live view is gone, so nothing is being captured.
      await _pumpBanner(tester, _active(receiving: false));

      expect(find.byKey(const Key('device-recording-dot')), findsNothing);
      expect(find.byIcon(AppIcons.recordFill), findsNothing);
      expect(
        tester
            .widget<Icon>(find.byKey(const Key('device-recording-paused')))
            .icon,
        AppIcons.pauseCircle,
      );
      expect(find.textContaining('paused'), findsWidgets);
      expect(find.text('00:42'), findsOneWidget);
    });
  });

  testWidgets('idle: no banner, and no timer left ticking', (tester) async {
    await _pumpBanner(tester, const DeviceRecordingIdle());
    expect(find.byIcon(AppIcons.recordFill), findsNothing);
    expect(find.byKey(const Key('device-recording-elapsed')), findsNothing);
    expect(StatusSpinnerClock.instance.isRunning, isFalse);
  });

  testWidgets('the clock ticks only while a recording runs', (tester) async {
    var builds = 0;
    Future<void> pump(DeviceRecordingState state) => tester.pumpWidget(
      ProviderScope(
        overrides: [deviceClockProvider.overrideWithValue(_Clock(testTime))],
        child: RecordingClock(
          recording: state,
          builder: (context, now) {
            builds++;
            return const SizedBox();
          },
        ),
      ),
    );

    await pump(const DeviceRecordingIdle());
    builds = 0;
    await tester.pump(RecordingClock.tick * 3);
    expect(builds, 0, reason: 'nothing recording, nothing rebuilt');

    await pump(_active());
    builds = 0;
    await tester.pump(RecordingClock.tick);
    await tester.pump(RecordingClock.tick);
    expect(builds, 2);

    await pump(const DeviceRecordingIdle());
    builds = 0;
    await tester.pump(RecordingClock.tick * 3);
    expect(builds, 0, reason: 'the timer stopped with the recording');
  });
}
