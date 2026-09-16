import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_companion/widgets.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';

import 'companion_test_support.dart';

/// The pieces every companion form shares: its one action and its inline error.
void main() {
  testWidgets('the primary button shows its glyph and can be pressed', (
    tester,
  ) async {
    var pressed = 0;
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(),
      home: CompanionPrimaryButton(
        label: 'Start session',
        icon: AppIcons.play,
        onPressed: () => pressed++,
      ),
    );

    expect(find.byIcon(AppIcons.play), findsOneWidget);
    expect(find.byType(InlineSpinner), findsNothing);
    await tester.tap(find.text('Start session'));
    expect(pressed, 1);
  });

  testWidgets('a busy primary button spins and cannot be pressed again', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(),
      home: CompanionPrimaryButton(
        busy: true,
        label: 'Starting…',
        icon: AppIcons.play,
        onPressed: () {},
      ),
    );

    expect(find.byType(InlineSpinner), findsOneWidget);
    expect(find.byIcon(AppIcons.play), findsNothing);
    expect(
      tester.widget<ButtonStyleButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });

  testWidgets('the inline error says its sentence beside a warning glyph', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(),
      home: const CompanionInlineError('That folder is gone.'),
    );

    final text = tester.widget<Text>(find.text('That folder is gone.'));
    final icon = tester.widget<Icon>(find.byIcon(AppIcons.warningCircle));
    final scheme = Theme.of(tester.element(find.byType(Text))).colorScheme;
    expect(text.style?.color, scheme.error);
    expect(icon.color, scheme.error);
  });
}
