import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/quick_open/quick_open_list.dart';
import 'package:karmashala_ui/icons.dart';

void main() {
  testWidgets('a long detail ends rather than pushing the row out', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 240,
              child: QuickOpenRow(
                icon: AppIcons.terminal,
                title: 'zsh',
                subtitle: 'Karmashala · app',
                detail: 'current · running claude in session/fix-the-login',
                selected: false,
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.textContaining('current · running'), findsOneWidget);
  });

  group('open to the side', () {
    Future<void> pumpRow(
      WidgetTester tester, {
      required bool selected,
      VoidCallback? onOpenBeside,
      VoidCallback? onTap,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 360,
              child: QuickOpenRow(
                icon: AppIcons.article,
                title: 'main.dart',
                subtitle: 'lib/main.dart',
                detail: 'modified',
                selected: selected,
                onTap: onTap ?? () {},
                onOpenBeside: onOpenBeside,
                besideTooltip: 'Open to the side (Ctrl+Enter)',
              ),
            ),
          ),
        ),
      ),
    );

    final button = find.byIcon(AppIcons.squareSplitHorizontal);

    testWidgets('the keyboard row shows the button, and it opens beside', (
      tester,
    ) async {
      var beside = 0;
      var plain = 0;
      await pumpRow(
        tester,
        selected: true,
        onOpenBeside: () => beside++,
        onTap: () => plain++,
      );

      expect(button, findsOneWidget);
      expect(find.byTooltip('Open to the side (Ctrl+Enter)'), findsOneWidget);
      await tester.tap(button);
      expect(beside, 1);
      expect(plain, 0, reason: 'the button is not a tap on the row');
    });

    testWidgets('a row neither hovered nor selected keeps it out of the way', (
      tester,
    ) async {
      await pumpRow(tester, selected: false, onOpenBeside: () {});
      expect(button, findsNothing);
    });

    testWidgets('a row that opens no tab never shows it', (tester) async {
      await pumpRow(tester, selected: true);
      expect(button, findsNothing);
    });
  });
}
