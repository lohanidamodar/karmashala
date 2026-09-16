import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_companion/screens.dart';
import 'package:karmashala_companion/widgets.dart';
import 'package:karmashala_remote/companion.dart';

import 'companion_test_support.dart';

/// The outage banner sits above every screen, so it may not become the screen.
void main() {
  const reason =
      'The relay hung up saying nobody was there: your desktop has not '
      'connected to it since it went to sleep, so there is nothing to reach.';

  FakeCompanionGateway down() =>
      FakeCompanionGateway.paired(link: CompanionLinkState.disconnected)
        ..linkTrouble = reason;

  for (final (size, scale) in const [
    (Size(320, 640), 1.0),
    (Size(320, 640), 1.3),
    (Size(320, 640), 2.0),
    (Size(360, 800), 2.0),
  ]) {
    testWidgets(
      'takes under 40% of a ${size.width.toInt()}x${size.height.toInt()} '
      'screen at ${scale}x text, Retry still offered',
      (tester) async {
        final errors = <FlutterErrorDetails>[];
        final previous = FlutterError.onError;
        FlutterError.onError = errors.add;
        try {
          await pumpPhone(
            tester,
            size: size,
            textScale: scale,
            gateway: down(),
            home: const Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [LinkBanner(), Expanded(child: SizedBox())],
            ),
          );
          await tester.pump();
        } finally {
          FlutterError.onError = previous;
        }

        expect(errors.map((e) => '${e.exception}'), isEmpty);
        expect(
          tester.getSize(find.byType(LinkBanner)).height,
          lessThan(size.height * 0.4),
        );
        expect(find.text('Retry'), findsOneWidget);
      },
    );
  }

  testWidgets('keeps one row on a phone at 1x text', (tester) async {
    await pumpPhone(
      tester,
      size: const Size(360, 800),
      gateway: down(),
      home: const Column(children: [LinkBanner()]),
    );
    await tester.pump();

    final retry = tester.getRect(find.text('Retry'));
    final headline = tester.getRect(find.text('Host unreachable'));
    expect(retry.left, greaterThan(headline.left));
    expect(retry.left, greaterThanOrEqualTo(headline.right));
  });

  testWidgets('the add-project screen keeps its form under the banner at 2x', (
    tester,
  ) async {
    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;
    try {
      await pumpPhone(
        tester,
        size: const Size(320, 640),
        textScale: 2.0,
        gateway: down(),
        home: const AddProjectScreen(),
      );
      await tester.pump();
    } finally {
      FlutterError.onError = previous;
    }
    expect(
      errors.map((e) => '${e.exception}'),
      isNot(contains(contains('overflowed'))),
    );
  });
}
