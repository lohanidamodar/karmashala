import 'package:flutter/material.dart';
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
  Widget form() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'Choose where the session starts and what it is told first. Every '
        'field below is optional; the defaults are the project\'s own.',
      ),
      for (var i = 0; i < 8; i++) ...[
        const SizedBox(height: Insets.md),
        TextField(decoration: InputDecoration(labelText: 'Field ${i + 1}')),
      ],
    ],
  );

  Widget dialog() => MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(
      body: AlertDialog(
        title: const DesktopDialogTitle(
          icon: AppIcons.chatCircleDots,
          title: 'Continue with…',
        ),
        content: BoundedDialogContent(
          width: DialogWidth.regular,
          child: form(),
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

  test('the width tokens are the three the dialogs converge on', () {
    expect(DialogWidth.narrow, lessThan(DialogWidth.regular));
    expect(DialogWidth.regular, lessThan(DialogWidth.wide));
  });
}
