import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import 'support/layout_probe.dart';

/// A saved thing on a settings page: variables, snippets and automations. Moved
/// here from the environment-variables feature, which the other two imported.
void main() {
  Widget card() => ItemCard(
    icon: AppIcons.terminal,
    title: const Text('A_RATHER_LONG_ENVIRONMENT_VARIABLE_NAME_FOR_A_TOKEN'),
    trailing: Switch(value: true, onChanged: (_) {}),
    details: const [Text('Secret · added 2026-09-16 · used by every terminal')],
    actions: [
      TextButton.icon(
        onPressed: () {},
        icon: const Icon(AppIcons.pencilSimple),
        label: const Text('Edit'),
      ),
      TextButton.icon(
        onPressed: () {},
        icon: const Icon(AppIcons.copy),
        label: const Text('Duplicate'),
      ),
      TextButton.icon(
        onPressed: () {},
        icon: const Icon(AppIcons.trash),
        label: const Text('Remove'),
      ),
    ],
    footer: const [Text('Last run: yesterday, passed')],
  );

  for (final width in [240.0, 390.0, 700.0]) {
    for (final scale in sweepScales) {
      for (final density in UiDensity.values) {
        testWidgets('fits ${width.toInt()}px at ${scale}x, ${density.name}', (
          tester,
        ) async {
          final overflows = await pumpInBox(
            tester,
            width: width,
            textScale: scale,
            density: density,
            child: SingleChildScrollView(child: card()),
          );
          expect(overflows, isEmpty);
        });
      }
    }
  }

  testWidgets('draws every slot, in order', (tester) async {
    await pumpInBox(tester, width: 700, child: card());
    double top(Finder f) => tester.getRect(f).top;
    final title = find.textContaining('A_RATHER_LONG');
    expect(find.byIcon(AppIcons.terminal), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
    expect(top(find.textContaining('Secret')), greaterThan(top(title)));
    expect(
      top(find.text('Edit')),
      greaterThan(top(find.textContaining('Secret'))),
    );
    expect(
      top(find.textContaining('Last run')),
      greaterThan(top(find.text('Edit'))),
    );
  });

  testWidgets('the actions wrap rather than overflow', (tester) async {
    await pumpInBox(tester, width: 240, child: card());
    expect(top(tester, 'Remove'), greaterThan(top(tester, 'Edit')));
  });

  testWidgets('with no icon the title starts at the padding', (tester) async {
    await pumpInBox(
      tester,
      width: 400,
      child: const ItemCard(title: Text('snippet')),
    );
    final card = tester.getRect(find.byType(Card));
    expect(tester.getRect(find.text('snippet')).left, card.left + Insets.md);
  });
}

double top(WidgetTester tester, String text) =>
    tester.getRect(find.text(text)).top;
