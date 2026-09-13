import 'package:flutter/foundation.dart';
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

  /// The gutter, which is painted rather than built — so what a test can read
  /// is the widget's own arithmetic, not a `Text` per line.
  CodeGutter gutter(WidgetTester tester) =>
      tester.widget<CodeGutter>(find.byType(CodeGutter));

  /// The line box the field actually produced. The engine's answer is not
  /// `fontSize * kCodeLineHeight` to the pixel, so the gutter takes its row
  /// height from the same layout rather than multiplying it out.
  double rowHeight(WidgetTester tester) => gutter(tester).rowHeight;

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    bool showLineNumbers = true,
    bool readOnly = false,
    double fontSize = 13,
    VoidCallback? onSave,
    int? revealLine,
    TextScaler scaler = TextScaler.noScaling,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: scaler),
              child: CodeField(
                controller: controller,
                showLineNumbers: showLineNumbers,
                readOnly: readOnly,
                fontSize: fontSize,
                onSave: onSave,
                revealLine: revealLine,
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'one number per line, and no number for a line that is not there',
    (tester) async {
      controller.text = 'alpha\nbeta\ngamma';
      await pump(tester);

      expect(gutter(tester).lineCount, 3);
    },
  );

  testWidgets('an empty buffer still has line one', (tester) async {
    await pump(tester);

    expect(gutter(tester).lineCount, 1);
  });

  testWidgets('the gutter draws the rows on screen, never the file', (
    tester,
  ) async {
    // The whole reason it is painted: a hundred thousand lines must cost a
    // screenful, and the arithmetic that decides that is worth pinning.
    const rows = 18.0;
    expect(
      visibleGutterRows(
        lineCount: 100000,
        rowHeight: rows,
        offset: 0,
        height: 900,
      ),
      (first: 0, last: 49),
    );
    // Scrolled a long way down: still a screenful, and it starts where the
    // viewport does rather than at line one.
    final deep = visibleGutterRows(
      lineCount: 100000,
      rowHeight: rows,
      offset: 90000,
      height: 900,
    );
    expect(deep.first, 5000);
    expect(deep.last - deep.first, lessThan(60));
    // The end of the file is the end of the gutter, not one row past it.
    expect(
      visibleGutterRows(lineCount: 10, rowHeight: rows, offset: 0, height: 900),
      (first: 0, last: 9),
    );
    // Nothing to draw is an empty range, never a negative loop.
    expect(
      visibleGutterRows(lineCount: 0, rowHeight: rows, offset: 0, height: 900),
      (first: 0, last: -1),
    );
    expect(
      visibleGutterRows(lineCount: 5, rowHeight: 0, offset: 0, height: 900),
      (first: 0, last: -1),
    );
  });

  testWidgets('and never a row outside its own box', (tester) async {
    // Ten rows fit exactly: the eleventh would be painted past the bottom of
    // a CustomPaint that clipped nothing.
    expect(
      visibleGutterRows(lineCount: 100, rowHeight: 10, offset: 0, height: 100),
      (first: 0, last: 9),
    );
    // A row height the layout produced rather than one a test chose: the last
    // row is half on screen and is still drawn.
    expect(
      visibleGutterRows(
        lineCount: 100,
        rowHeight: 18.2,
        offset: 0,
        height: 100,
      ),
      (first: 0, last: 5),
    );
    expect(
      visibleGutterRows(
        lineCount: 100,
        rowHeight: 18.2,
        offset: 9.1,
        height: 100,
      ),
      (first: 0, last: 5),
    );
    // Overscrolled past the top: the first row is still row one.
    expect(
      visibleGutterRows(
        lineCount: 100,
        rowHeight: 10,
        offset: -50,
        height: 100,
      ),
      (first: 0, last: 4),
    );
    // Scrolled past the end: nothing to draw, and no reversed loop.
    final past = visibleGutterRows(
      lineCount: 100,
      rowHeight: 10,
      offset: 2000,
      height: 100,
    );
    expect(past.first, greaterThan(past.last));
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

  testWidgets('the gutter is as tall as the code, row for row', (tester) async {
    controller.text = 'a\nb\nc';
    await pump(tester);

    // The one invariant a painted gutter still has to keep: its row height is
    // the field's line box, so row n stands beside line n at any scroll.
    final field = tester.getSize(find.byType(TextField)).height;
    expect(rowHeight(tester) * gutter(tester).lineCount, closeTo(field, 0.01));
  });

  // Flutter's paragraph layout breaks on more than a line feed, so a gutter
  // that counts only `\n` numbers rows the field is not drawing.
  const separators = <String, String>{
    r'\n': '\n',
    r'\v (vertical tab)': '\u000B',
    r'\f (form feed)': '\u000C',
    r'U+2028 (line separator)': '\u2028',
    r'U+2029 (paragraph separator)': '\u2029',
  };
  separators.forEach((name, separator) {
    testWidgets('$name is one line break, in the gutter and in the field', (
      tester,
    ) async {
      controller.text = 'alpha${separator}beta${separator}gamma';
      await pump(tester);

      expect(gutter(tester).lineCount, 3);
      // The count is only right if it is the count of rows actually drawn.
      final field = tester.getSize(find.byType(TextField)).height;
      expect(rowHeight(tester) * 3, closeTo(field, 0.01));
    });
  });

  testWidgets('showLineNumbers: false draws no numbers', (tester) async {
    controller.text = 'alpha\nbeta';
    await pump(tester, showLineNumbers: false);

    expect(find.byType(CodeGutter), findsNothing);
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

  testWidgets('Ctrl+Shift+S is a different chord and saves nothing', (
    tester,
  ) async {
    var saves = 0;
    controller.text = 'a';
    await pump(tester, onSave: () => saves++);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(saves, 0);
  });

  testWidgets('on macOS the chord is Cmd+S, and Ctrl+S is not it', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    var saves = 0;
    controller.text = 'a';
    await pump(tester, onSave: () => saves++);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(saves, 0);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    // Unset inside the body: the binding checks for a leaked debug variable
    // before any tearDown runs.
    debugDefaultTargetPlatformOverride = null;

    expect(saves, 1);
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

  testWidgets('a minified line is measured from a sample, and still fits', (
    tester,
  ) async {
    // The measurement is capped at kMaxLineUnitsLaidOut code units, so the
    // width past it is extrapolated — and the line must still not wrap, or
    // the gutter would number rows the buffer does not have.
    const units = 40 * kMaxLineUnitsLaidOut;
    controller.text = 'x' * units;
    await pump(tester, size: const Size(390, 844));

    final field = tester.getSize(find.byType(TextField));
    expect(field.height, lessThan(rowHeight(tester) * 2));
    expect(gutter(tester).lineCount, 1);
    // The sample is a fortieth of the line; the box is still the whole line.
    final sample = tester.renderObject<RenderBox>(find.byType(TextField));
    expect(sample.size.width, greaterThan(units * 0.9));
  });

  testWidgets('it draws at a text scale §5 asks for', (tester) async {
    controller.text = 'alpha\nbeta\ngamma';
    await pump(tester);
    final unscaled = gutter(tester);

    await pump(tester, scaler: const TextScaler.linear(1.8));
    final scaled = gutter(tester);

    expect(tester.takeException(), isNull);
    expect(scaled.rowHeight, greaterThan(unscaled.rowHeight));
    expect(scaled.width, greaterThan(unscaled.width));
    // The row is still the field's own line box at any scale.
    final field = tester.getSize(find.byType(TextField)).height;
    expect(scaled.rowHeight * 3, closeTo(field, 0.01));
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
      expect(gutter(tester).lineCount, greaterThanOrEqualTo(60));
      expect(find.byType(CodeField), findsOneWidget);
    });
  }
}
