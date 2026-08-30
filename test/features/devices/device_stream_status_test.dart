import 'package:chitragupta/src/features/devices/data/device_gesture_sink.dart';
import 'package:chitragupta/src/features/devices/data/device_stream.dart';
import 'package:chitragupta/src/features/devices/presentation/device_stream_status.dart';
import 'package:chitragupta/src/features/devices/presentation/device_touch_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  group('StreamStalledOverlay', () {
    testWidgets('a frozen picture is labelled, not left to look live', (
      tester,
    ) async {
      // This is the bug it exists for: the last decoded frame stayed on screen
      // for as long as the pane was open, and a dead stream is visually
      // identical to a device sitting on a static screen.
      await _pump(
        tester,
        StreamStalledOverlay(
          health: const DeviceStreamHealth(
            state: DeviceStreamState.stalled,
            detail: 'No data from the device for 8s.',
          ),
          exhausted: false,
          onRestart: () {},
        ),
      );
      expect(find.text('Live view frozen'), findsOneWidget);
      expect(find.text('No data from the device for 8s.'), findsOneWidget);
      expect(find.text('Restart live view'), findsOneWidget);
    });

    testWidgets('a stream that ended says so, in different words', (
      tester,
    ) async {
      await _pump(
        tester,
        StreamStalledOverlay(
          health: const DeviceStreamHealth(
            state: DeviceStreamState.ended,
            detail: 'scrcpy-server exited (code 143).',
          ),
          exhausted: true,
          onRestart: () {},
        ),
      );
      expect(find.text('Live view disconnected'), findsOneWidget);
      expect(find.text('Live view frozen'), findsNothing);
    });

    testWidgets('shows what the server said before it died', (tester) async {
      // Observed on a physical device: the server had exited and nothing in the
      // app knew why, because its stderr went to a log nobody reads.
      await _pump(
        tester,
        StreamStalledOverlay(
          health: const DeviceStreamHealth(
            state: DeviceStreamState.ended,
            detail: 'scrcpy-server exited (code 143).',
            serverLog: ['ERROR: Could not find display id 0'],
          ),
          exhausted: true,
          onRestart: () {},
        ),
      );
      expect(find.text('ERROR: Could not find display id 0'), findsOneWidget);
    });

    testWidgets('says it is reconnecting only while it still is', (
      tester,
    ) async {
      await _pump(
        tester,
        StreamStalledOverlay(
          health: const DeviceStreamHealth(
            state: DeviceStreamState.ended,
            detail: 'gone',
          ),
          exhausted: false,
          onRestart: () {},
        ),
      );
      expect(find.text('Reconnecting…'), findsOneWidget);

      await _pump(
        tester,
        StreamStalledOverlay(
          health: const DeviceStreamHealth(
            state: DeviceStreamState.ended,
            detail: 'gone',
          ),
          exhausted: true,
          onRestart: () {},
        ),
      );
      // Retrying forever in silence is the failure, not the fix.
      expect(find.text('Reconnecting…'), findsNothing);
      expect(find.text('Restart live view'), findsOneWidget);
    });

    testWidgets('the restart button is the way out', (tester) async {
      var restarts = 0;
      await _pump(
        tester,
        StreamStalledOverlay(
          health: const DeviceStreamHealth(
            state: DeviceStreamState.ended,
            detail: 'gone',
          ),
          exhausted: true,
          onRestart: () => restarts += 1,
        ),
      );
      await tester.tap(find.text('Restart live view'));
      await tester.pump();
      expect(restarts, 1);
    });
  });

  group('TransportBanner', () {
    testWidgets('names the control socket and how to pinch', (tester) async {
      await _pump(
        tester,
        const TransportBanner(transport: DeviceGestureTransport.scrcpyControl),
      );
      expect(find.textContaining('Control socket'), findsOneWidget);
      expect(find.textContaining(kPinchHint), findsOneWidget);
    });

    testWidgets('admits the fallback cannot do the same things', (
      tester,
    ) async {
      // The two transports feel completely different — one tracks the finger,
      // one applies the whole gesture on release — so which is active is not an
      // implementation detail to hide.
      await _pump(
        tester,
        const TransportBanner(transport: DeviceGestureTransport.adbInput),
      );
      expect(find.textContaining('on release'), findsOneWidget);
      expect(find.textContaining('no pinch'), findsOneWidget);
    });

    testWidgets('says so when there is no input at all', (tester) async {
      await _pump(tester, const TransportBanner(transport: null));
      expect(find.text('Input unavailable'), findsOneWidget);
    });
  });
}
