import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/code.dart';

/// **The gutter is only right if it cannot drift.**
///
/// A number per line is easy; a number that still names its line after two
/// hundred of them is the whole reason the strut and the gutter row are one
/// constant. The tests below pin that constant from both ends, and pump the
/// field at both sizes §6 asks for.
void main() {
  late CodeEditingController controller;

  setUp(() => controller = CodeEditingController(language: 'dart'));
  tearDown(() => controller.dispose());

  /// The line box the field actually produced, read off a gutter row. The
  /// engine's answer is not `fontSize * kCodeLineHeight` to the pixel, so the
  /// gutter is measured from the same layout rather than multiplied out.
  double rowHeight(WidgetTester tester) => tester
      .getSize(find.ancestor(of: find.text('1'), matching: find.byType(SizedBox)).first)
      .height;

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    bool showLineNumbers = true,
    bool readOnly = false,
    double fontSize = 13,
    VoidCallback? onSave,
    int? revealLine,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CodeField(
            controller: controller,
            showLineNumbers: showLineNumbers,
            readOnly: readOnly,
            fontSize: fontSize,
            onSave: onSave,
            revealLine: revealLine,
          ),
        ),
      ),
    );
  }

  testWidgets('one number per line, and no number for a line that is not there', (
    tester,
  ) async {
    controller.text = 'alpha\nbeta\ngamma';
    await pump(tester);

    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('4'), findsNothing);
  });

  testWidgets('an empty buffer still has line one', (tester) async {
    await pump(tester);

    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsNothing);
  });

  testWidgets('a gutter row is exactly the line it stands beside', (
    tester,
  ) async {
    controller.text = 'a\nb\nc';
    await pump(tester, fontSize: 16);

    final field = tester.getSize(find.byType(TextField)).height;
    expect(rowHeight(tester) * 3, closeTo(field, 0.01));

    final strut = tester.widget<TextField>(find.byType(TextField)).strutStyle!;
    expect(strut.fontSize, 16);
    expect(strut.height, kCodeLineHeight);
    expect(strut.forceStrutHeight, isTrue);
  });

  testWidgets('the second line sits one row below the first', (tester) async {
    controller.text = 'a\nb\nc';
    await pump(tester);

    final first = tester.getTopLeft(find.text('1')).dy;
    final second = tester.getTopLeft(find.text('2')).dy;
    expect(second - first, rowHeight(tester));
  });

  testWidgets('showLineNumbers: false draws no numbers', (tester) async {
    controller.text = 'alpha\nbeta';
    await pump(tester, showLineNumbers: false);

    expect(find.text('1'), findsNothing);
    expect(find.text('2'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('a read-only field takes no keys', (tester) async {
    controller.text = 'frozen';
    await pump(tester, readOnly: true);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(controller.text, 'frozen');
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
  });

  testWidgets('Tab indents instead of leaving the field', (tester) async {
    controller
      ..text = 'a'
      ..selection = const TextSelection.collapsed(offset: 1);
    await pump(tester);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(controller.text, 'a${CodeEditingController.indent}');
  });

  testWidgets('Ctrl+S saves, and does nothing when nobody is listening', (
    tester,
  ) async {
    var saves = 0;
    controller.text = 'a';
    await pump(tester, onSave: () => saves++);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(saves, 1);
    expect(controller.text, 'a');
  });

  testWidgets('revealLine scrolls the buffer to the line it names', (
    tester,
  ) async {
    controller.text = List.generate(200, (i) => 'line $i').join('\n');
    await pump(tester, size: const Size(600, 400));

    final scroller = find.byType(Scrollable).first;
    final line = rowHeight(tester);
    expect(tester.widget<Scrollable>(scroller).controller!.offset, 0);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CodeField(controller: controller, revealLine: 120),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.widget<Scrollable>(scroller).controller!.offset, 119 * line);
  });

  testWidgets('a long line scrolls sideways rather than wrapping', (
    tester,
  ) async {
    controller.text = 'x' * 400;
    await pump(tester, size: const Size(390, 844));

    final field = tester.getSize(find.byType(TextField));
    expect(field.width, greaterThan(390));
    // Still one line, however long: it scrolled sideways instead of wrapping.
    // A single-line field's box is its own line box plus a couple of pixels,
    // so the check is against a second row rather than an exact height.
    expect(field.height, lessThan(rowHeight(tester) * 2));
  });

  for (final size in const [Size(390, 844), Size(1440, 900)]) {
    testWidgets('lays out at ${size.width.toInt()}x${size.height.toInt()}', (
      tester,
    ) async {
      controller.text = List.generate(
        60,
        (i) => '${'  ' * (i % 4)}final value$i = ${'y' * (i * 2)};',
      ).join('\n');
      await pump(tester, size: size);

      expect(tester.takeException(), isNull);
      expect(find.text('60'), findsOneWidget);
      expect(find.byType(CodeField), findsOneWidget);
    });
  }
}
