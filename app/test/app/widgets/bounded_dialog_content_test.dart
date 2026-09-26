import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/window_matrix.dart';

/// The dialog body that fits the minimum window. About 40 dialogs wrote
/// `content: SizedBox(width: 460, child: Column(...))`: at 720x560 and 1.3x
/// text the About dialog overflowed 51px, and a longer form put five of its
/// focus stops outside the window where Tab could reach them and nobody could
/// see them.
void main() {
  /// A form taller than the minimum window: a paragraph and eight fields.
  Widget form({int fields = 8}) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'Choose where the session starts and what it is told first. Every '
        'field below is optional; the defaults are the project\'s own.',
      ),
      for (var i = 0; i < fields; i++) ...[
        const SizedBox(height: Insets.md),
        TextField(decoration: InputDecoration(labelText: 'Field ${i + 1}')),
      ],
    ],
  );

  Widget dialog({int fields = 8}) => MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(
      body: AlertDialog(
        title: const DesktopDialogTitle(
          icon: AppIcons.chatCircleDots,
          title: 'Continue with…',
        ),
        content: BoundedDialogContent(
          width: DialogWidth.regular,
          child: form(fields: fields),
        ),
        actions: [
          TextButton(onPressed: () {}, child: const Text('Cancel')),
          FilledButton(onPressed: () {}, child: const Text('Continue')),
        ],
      ),
    ),
  );

  testWidgets('a tall form survives the minimum window and large text', (
    tester,
  ) async {
    await expectSurvivesWindowMatrix(
      tester,
      matrix: const [minimumWindow, minimumWindowLargeText, desktopWindow],
      build: dialog,
      because: 'the body scrolls inside the window and Tab reveals each field',
    );
  });

  testWidgets('it is the design width when there is room, and shrinks when '
      'there is not', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;

    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpWidget(dialog());
    expect(
      tester.getSize(find.byType(BoundedDialogContent)).width,
      DialogWidth.regular,
    );

    tester.view.physicalSize = const Size(400, 560);
    await tester.pumpWidget(dialog());
    expect(
      tester.getSize(find.byType(BoundedDialogContent)).width,
      lessThan(400),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the last field is reachable by scrolling', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(720, 560);
    await tester.pumpWidget(dialog());
    final last = find.widgetWithText(TextField, 'Field 8');
    await tester.ensureVisible(last);
    await tester.pumpAndSettle();
    await tester.tap(last);
    await tester.pump();
    expect(
      tester
          .widget<EditableText>(
            find.descendant(of: last, matching: find.byType(EditableText)),
          )
          .focusNode
          .hasFocus,
      isTrue,
    );
  });

  testWidgets('Tab arriving at, or moving back to, a button scrolled off the '
      'top brings it into view', (tester) async {
    // Flutter's own traversal keeps only the edge Tab is moving towards, so a
    // wrap from the last stop left focus on a control nobody could see. Buttons,
    // not fields: a text field reveals itself when it is focused.
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(720, 560);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: AlertDialog(
            title: const Text('Choose'),
            content: BoundedDialogContent(
              width: DialogWidth.regular,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 1; i <= 40; i++)
                    OutlinedButton(onPressed: () {}, child: Text('Choice $i')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final viewport = tester.getRect(find.byType(SingleChildScrollView));
    final first = find.widgetWithText(OutlinedButton, 'Choice 1');
    Future<void> scrollToTheEnd() async {
      await tester.ensureVisible(find.text('Choice 40'));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(first).bottom,
        lessThan(viewport.top),
        reason: 'the premise: the first button is scrolled out of view',
      );
    }

    // Arriving: nothing in the body is focused, so the dialog's policy moves.
    await scrollToTheEnd();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(tester.getRect(first).top, greaterThanOrEqualTo(viewport.top));

    // Moving back: within the body, Shift+Tab to a stop above the viewport.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await scrollToTheEnd();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(tester.getRect(first).top, greaterThanOrEqualTo(viewport.top));
  });

  test('the width tokens are the three the dialogs converge on', () {
    expect(DialogWidth.narrow, lessThan(DialogWidth.regular));
    expect(DialogWidth.regular, lessThan(DialogWidth.wide));
  });
}
