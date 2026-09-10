import 'package:karmashala_devices/devices.dart';
import 'package:karmashala_devices/widgets.dart';
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

  group('StreamIdleBadge', () {
    testWidgets('says the picture is standing still, and stops there', (
      tester,
    ) async {
      // A phone on a desk sends no frames at all. Saying so is useful; dimming
      // the picture and offering to restart is what turned an untouched device
      // into nine minutes of reconnecting.
      await _pump(tester, const StreamIdleBadge(detail: 'No screen changes for 20s.'));
      expect(find.text('No screen changes for 20s.'), findsOneWidget);
      expect(find.text('Restart live view'), findsNothing);
      expect(find.text('Live view frozen'), findsNothing);
    });
  });

  group('HeldPicture', () {
    testWidgets('cannot be built without the overlay that explains it', (
      tester,
    ) async {
      // The dangerous shape this widget exists to make impossible: a frozen
      // frame on screen with nothing saying it is frozen. The picture and the
      // label are one widget, so no later edit can separate them.
      await _pump(
        tester,
        const SizedBox(
          width: 300,
          height: 500,
          child: HeldPicture(
            deviceLabel: 'Pixel',
            child: ColoredBox(color: Color(0xFF00FF00)),
          ),
        ),
      );
      expect(find.byType(ColoredBox), findsWidgets);
      expect(find.text('Reconnecting…'), findsOneWidget);
      expect(find.textContaining('not a live picture'), findsOneWidget);
    });
  });

  group('StreamIdleBadge', () {
    testWidgets('offers the way out, because this is the state the app cannot '
        'be sure about', (tester) async {
      var restarts = 0;
      await _pump(
        tester,
        StreamIdleBadge(
          detail: 'No screen changes for 20s.',
          since: const Duration(seconds: 20),
          onRestart: () => restarts += 1,
        ),
      );
      await tester.tap(find.text('Reconnect'));
      await tester.pump();
      expect(restarts, 1);
    });

    testWidgets('stops claiming certainty once it has been a while', (
      tester,
    ) async {
      // A device quiet for twenty seconds is a device on a desk. One quiet for
      // five minutes might equally be a live view that stopped working, and
      // the app cannot tell the difference — so it says so.
      await _pump(
        tester,
        const StreamIdleBadge(
          detail: 'No screen changes for 20s.',
          since: Duration(seconds: 20),
        ),
      );
      expect(find.textContaining('may be out of date'), findsNothing);

      await _pump(
        tester,
        const StreamIdleBadge(
          detail: 'No screen changes for 300s.',
          since: Duration(seconds: 300),
        ),
      );
      expect(find.textContaining('may be out of date'), findsOneWidget);
    });
  });

  group('StreamReconnectingOverlay', () {
    testWidgets('a held frame is never allowed to look live', (tester) async {
      // The frame underneath is the last one the device sent, kept so a restart
      // does not blink the picture out. It is also, by definition, out of date.
      await _pump(tester, const StreamReconnectingOverlay(deviceLabel: 'Pixel'));
      expect(find.text('Reconnecting…'), findsOneWidget);
      expect(find.textContaining('last frame received'), findsOneWidget);
      expect(find.textContaining('not a live picture'), findsOneWidget);
      expect(find.textContaining('Pixel'), findsOneWidget);
    });

    testWidgets('still says it with no device to name', (tester) async {
      await _pump(tester, const StreamReconnectingOverlay(deviceLabel: null));
      expect(find.textContaining('not a live picture'), findsOneWidget);
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

    testWidgets('names the device whose picture is on screen', (tester) async {
      // A picture of a phone is anonymous. The pane could show one device while
      // the toolbar named another, so what you are looking at is now stated
      // where you are looking.
      await _pump(
        tester,
        const TransportBanner(
          transport: DeviceGestureTransport.scrcpyControl,
          deviceLabel: 'Pixel (emulator-5554)',
        ),
      );
      expect(find.textContaining('Pixel (emulator-5554)'), findsOneWidget);
      expect(find.textContaining('Control socket'), findsOneWidget);
    });
  });
}
