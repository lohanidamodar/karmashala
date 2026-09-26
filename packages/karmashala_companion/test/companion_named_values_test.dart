import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_companion/widgets.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_ui/tokens.dart';

import 'companion_test_support.dart';

/// Sizes that used to be bare numbers, held to what their names promise.
void main() {
  List<double> boneHeights(WidgetTester tester) => [
    for (final box in tester.widgetList<Container>(
      find.descendant(
        of: find.byType(CompanionSkeletonList),
        matching: find.byType(Container),
      ),
    ))
      if (box.constraints?.maxHeight case final h? when h.isFinite) h,
  ];

  testWidgets('skeleton lines grow with the text they stand in for', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(),
      home: const CompanionSkeletonList(rows: 1),
    );
    final normal = boneHeights(tester);

    await pumpPhone(
      tester,
      textScale: 2.0,
      gateway: FakeCompanionGateway.paired(),
      home: const CompanionSkeletonList(rows: 1),
    );
    final large = boneHeights(tester);

    expect(normal, isNotEmpty);
    expect(large, [for (final h in normal) h * 2]);
  });

  testWidgets('a companion sheet covers at most its named share', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => companionSheet<void>(
            context,
            title: 'LONG',
            children: [
              for (var i = 0; i < 40; i++) ListTile(title: Text('row $i')),
            ],
          ),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byType(BottomSheet)).height,
      lessThanOrEqualTo(kPhoneSize.height * companionSheetMaxShare),
    );
  });

  testWidgets('the active machine badge keeps a hairline of ground', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(),
      home: const ConnectionsSection(),
    );
    final badge = tester.widget<Container>(
      find
          .ancestor(of: find.text('Active'), matching: find.byType(Container))
          .first,
    );
    expect(
      badge.padding,
      const EdgeInsets.symmetric(
        horizontal: Insets.xs,
        vertical: companionBadgeHairline,
      ),
    );
  });
}
