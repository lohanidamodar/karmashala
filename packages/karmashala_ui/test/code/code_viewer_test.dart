import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/code.dart';

/// **A viewer that builds the file has not solved anything.**
///
/// [CodeViewer] exists so a file too big to edit still opens, and the only
/// property that makes that true is that it draws the rows on screen and no
/// others. A test cannot time a frame reliably, so it counts widgets instead:
/// a hundred thousand lines must not become a hundred thousand `Text`s.
void main() {
  Future<void> pump(
    WidgetTester tester,
    String text, {
    Size size = const Size(1440, 900),
    bool showLineNumbers = true,
    int? revealLine,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CodeViewer(
            text: text,
            showLineNumbers: showLineNumbers,
            revealLine: revealLine,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// One drawn row, found by the text it carries.
  Finder row(String text) => find.text(text);

  String lines(int count) =>
      List.generate(count, (i) => 'line ${i + 1}').join('\n');

  testWidgets('it draws a screenful, whatever the file', (tester) async {
    await pump(tester, lines(100000));

    // A screenful at 900px and an ~18px row is around fifty, plus whatever the
    // list keeps as cache extent. The number that matters is that it is not
    // 100,000.
    expect(find.byType(Text).evaluate().length, lessThan(400));
    expect(row('line 1'), findsOneWidget);
    expect(row('line 100000'), findsNothing);
  });

  testWidgets('the gutter counts every line even so', (tester) async {
    await pump(tester, lines(100000));

    expect(
      tester.widget<CodeGutter>(find.byType(CodeGutter)).lineCount,
      100000,
    );
  });

  /// The rows the list actually built — the only honest counterpart to the
  /// number the gutter prints.
  Finder rows() =>
      find.descendant(of: find.byType(ListView), matching: find.byType(Text));

  // The paragraph layout breaks on more than a line feed, and a row is drawn
  // `maxLines: 1`: a separator the split misses is text nobody can scroll to.
  const separators = <String, String>{
    r'\n': '\n',
    r'\v (vertical tab)': '\u000B',
    r'\f (form feed)': '\u000C',
    r'U+2028 (line separator)': '\u2028',
    r'U+2029 (paragraph separator)': '\u2029',
  };
  separators.forEach((name, separator) {
    testWidgets('$name is one line break, and all three lines are drawn', (
      tester,
    ) async {
      await pump(tester, 'alpha${separator}beta${separator}gamma');

      expect(tester.widget<CodeGutter>(find.byType(CodeGutter)).lineCount, 3);
      expect(rows(), findsNWidgets(3));
      expect(row('alpha'), findsOneWidget);
      expect(row('beta'), findsOneWidget);
      expect(row('gamma'), findsOneWidget);
    });
  });

  testWidgets('showLineNumbers: false draws no gutter', (tester) async {
    await pump(tester, lines(10), showLineNumbers: false);

    expect(find.byType(CodeGutter), findsNothing);
    expect(row('line 1'), findsOneWidget);
  });

  testWidgets('an empty file is one empty line, not a crash', (tester) async {
    await pump(tester, '');

    expect(tester.widget<CodeGutter>(find.byType(CodeGutter)).lineCount, 1);
  });

  testWidgets('a file with no trailing newline keeps its last line', (
    tester,
  ) async {
    await pump(tester, 'alpha\nbeta');

    expect(row('alpha'), findsOneWidget);
    expect(row('beta'), findsOneWidget);
    expect(tester.widget<CodeGutter>(find.byType(CodeGutter)).lineCount, 2);
  });

  testWidgets('CRLF does not leave a carriage return on the row', (
    tester,
  ) async {
    // The buffer normalises endings, but a file read some other way can still
    // arrive with them, and a stray \r draws as a box.
    await pump(tester, 'alpha\r\nbeta\r\n');

    expect(row('alpha'), findsOneWidget);
    expect(row('beta'), findsOneWidget);
  });

  testWidgets('revealLine puts that line on screen', (tester) async {
    await pump(tester, lines(100000), revealLine: 5000);
    await tester.pump();

    expect(row('line 5000'), findsOneWidget);
    expect(row('line 1'), findsNothing);
  });

  testWidgets('it is read-only: no field to type into', (tester) async {
    await pump(tester, lines(10));

    expect(find.byType(TextField), findsNothing);
    expect(find.byType(EditableText), findsNothing);
  });

  testWidgets('it survives both window sizes §6 asks for', (tester) async {
    await pump(tester, lines(5000), size: const Size(390, 844));
    expect(tester.takeException(), isNull);

    await pump(tester, lines(5000), size: const Size(1440, 900));
    expect(tester.takeException(), isNull);
  });
}
