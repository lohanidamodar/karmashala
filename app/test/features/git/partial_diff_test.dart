import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/git/application/parsed_diff.dart';
import 'package:karmashala/src/features/git/presentation/diff_view.dart';
import 'package:karmashala_ui/theme.dart';

/// A diff too big to draw is drawn short — and **says so**. The rule the rest
/// of this repository applies to commands applies to a pane: never let what
/// could not be shown pass for the whole of it.
void main() {
  /// A patch of [changed] changed lines, in one hunk.
  String patch(int changed) => [
    '@@ -1,$changed +1,$changed @@',
    for (var i = 0; i < changed; i++) '-old $i',
    for (var i = 0; i < changed; i++) '+new $i',
  ].join('\n');

  group('ParsedDiff.parse', () {
    test('a patch inside the bound is whole, and says it is', () {
      final parsed = ParsedDiff.parse(patch(10), maxLines: 100);
      expect(parsed.isPartial, isFalse);
      expect(parsed.omittedLines, 0);
      expect(parsed.lines, hasLength(parsed.totalLines));
      expect(parsed.added, 10);
      expect(parsed.removed, 10);
    });

    test('past the bound it keeps the first rows and counts the rest', () {
      final parsed = ParsedDiff.parse(patch(50), maxLines: 20);
      expect(parsed.lines, hasLength(20));
      expect(parsed.totalLines, 101); // one hunk header + 50 − + 50 +
      expect(parsed.isPartial, isTrue);
      expect(parsed.omittedLines, 81);
      // The rows kept are the first ones, in order, not a sample.
      expect(parsed.lines.first.text, startsWith('@@'));
      expect(parsed.lines.last.text, '-old 18');
    });

    test('the +/− count is the whole patch, not the visible part', () {
      // A count taken over the drawn rows would quietly understate the change
      // while looking exactly like a real measurement.
      final parsed = ParsedDiff.parse(patch(50), maxLines: 5);
      expect(parsed.added, 50);
      expect(parsed.removed, 50);
    });

    test('line numbers are only ever computed for rows that exist', () {
      final parsed = ParsedDiff.parse(patch(50), maxLines: 20);
      expect(parsed.newLineNumbers, hasLength(parsed.lines.length));
    });

    test('the widest row is measured over what is drawn', () {
      // Sizing a scroll from a row nobody can reach would leave dead width.
      final text = ['@@ -1,2 +1,2 @@', '+short', '+${'x' * 500}'].join('\n');
      final parsed = ParsedDiff.parse(text, maxLines: 2);
      expect(parsed.widestLine, '@@ -1,2 +1,2 @@');
    });

    test('the default bound is the one the view draws with', () {
      expect(ParsedDiff.parse(patch(4)).isPartial, isFalse);
      expect(kDiffRowLimit, greaterThan(1000));
    });
  });

  group('PartialDiffBanner', () {
    Future<void> show(WidgetTester tester, ParsedDiff parsed) =>
        tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark(),
            home: Scaffold(body: PartialDiffBanner(parsed: parsed)),
          ),
        );

    testWidgets('names both counts, so neither can be mistaken for the other', (
      tester,
    ) async {
      await show(tester, ParsedDiff.parse(patch(50), maxLines: 20));
      expect(find.textContaining('Partial diff'), findsOneWidget);
      expect(find.textContaining('first 20 of 101 lines'), findsOneWidget);
      expect(find.textContaining('81'), findsOneWidget);
    });

    testWidgets('refuses to let the patch pass for the whole change', (
      tester,
    ) async {
      await show(tester, ParsedDiff.parse(patch(50), maxLines: 20));
      expect(find.textContaining('whole patch'), findsOneWidget);
      expect(find.textContaining('not proof'), findsOneWidget);
      // And says where the whole of it can be had.
      expect(find.textContaining('Copy diff'), findsOneWidget);
    });
  });
}
