import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_companion/pairing.dart';
import 'package:karmashala_remote/companion.dart';

import 'companion_test_support.dart';

/// Pairing screens at the sizes a phone and a tablet actually have, with the
/// text as large as a reader sets it.
void main() {
  group('the scan screen', () {
    for (final (size, scale) in const [
      (Size(320, 640), 2.0),
      (Size(360, 800), 2.0),
      (Size(800, 360), 2.0),
      (Size(360, 800), 1.0),
    ]) {
      testWidgets(
        'keeps at least half its body for the camera at '
        '${size.width.toInt()}x${size.height.toInt()} @$scale with an error',
        (tester) async {
          late ValueChanged<String> deliver;
          final errors = <FlutterErrorDetails>[];
          final previous = FlutterError.onError;
          FlutterError.onError = errors.add;
          try {
            await pumpPhone(
              tester,
              size: size,
              textScale: scale,
              gateway: FakeCompanionGateway(),
              home: ScanQrScreen(
                scannerBuilder: (context, onPayload) {
                  deliver = onPayload;
                  return const Placeholder();
                },
              ),
            );
            deliver('https://example.com/some-other-qr');
            await tester.pump();
          } finally {
            FlutterError.onError = previous;
          }

          expect(
            errors.map((e) => '${e.exception}'),
            isNot(contains(contains('overflowed'))),
          );
          final body = size.height - tester.getSize(find.byType(AppBar)).height;
          expect(
            tester.getSize(find.byType(Placeholder)).height,
            greaterThanOrEqualTo(body / 2 - 1),
          );
          expect(
            find.textContaining(
              'not a Karmashala pairing code',
              skipOffstage: false,
            ),
            findsOneWidget,
          );
          expect(
            find.text('Type the code instead', skipOffstage: false),
            findsOneWidget,
          );
        },
      );
    }
  });
}
