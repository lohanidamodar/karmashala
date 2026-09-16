import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:karmashala_devices/widgets.dart';
import 'package:karmashala_ui/theme.dart';

/// The stream status widgets at the sizes the picture really gets: a phone's
/// aspect ratio inside a side panel is a narrow box, and a short one once the
/// log is open under it.
Future<void> _pumpIn(WidgetTester tester, Size box, Widget child) async {
  tester.view
    ..physicalSize = const Size(800, 600)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Center(
          child: SizedBox.fromSize(size: box, child: child),
        ),
      ),
    ),
  );
}

void main() {
  group('StreamStalledOverlay keeps its way out', () {
    for (final box in const [Size(122, 120), Size(160, 200), Size(240, 120)]) {
      testWidgets('in ${box.width.toInt()}x${box.height.toInt()}', (
        tester,
      ) async {
        var restarts = 0;
        await _pumpIn(
          tester,
          box,
          StreamStalledOverlay(
            health: const DeviceStreamHealth(
              state: DeviceStreamState.ended,
              detail: 'scrcpy-server exited (code 143) after the device slept.',
              serverLog: ['ERROR: Could not find display id 0'],
            ),
            exhausted: false,
            onRestart: () => restarts += 1,
          ),
        );

        // A Column with no room clipped the button off the bottom of the
        // picture — the one control that gets the picture back.
        final restart = find.text('Restart live view');
        expect(restart.hitTestable(), findsOneWidget);
        final overlay = tester.getRect(find.byType(StreamStalledOverlay));
        final button = tester.getRect(restart);
        expect(overlay.contains(button.topLeft), isTrue);
        expect(overlay.contains(button.bottomRight), isTrue);

        await tester.tap(restart);
        expect(restarts, 1);
      });
    }
  });
}
