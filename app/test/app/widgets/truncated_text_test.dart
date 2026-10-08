import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/workbench_tab_chip.dart';
import 'package:karmashala/src/app/widgets/truncated_text.dart';

import '../../features/overview/mission_fixture.dart';

/// **A title names itself in full only once it is cut** (round 66, owner,
/// 2026-10-08): hover on a desktop, a long press under a thumb, and nothing
/// for a title that fits — in the peek, the tab strip and the dashboard's
/// cards alike.
void main() {
  const long =
      'karmashala new features - after open, a title long enough to be cut';

  /// The message over [text], '' when it has none.
  String tipOver(WidgetTester tester, Finder text) {
    final tips = find.ancestor(of: text, matching: find.byType(Tooltip));
    if (tips.evaluate().isEmpty) return '';
    return tester.widget<Tooltip>(tips.first).message ?? '';
  }

  bool cut(WidgetTester tester, Finder text) => tester
      .renderObject<RenderParagraph>(
        find.descendant(of: text, matching: find.byType(RichText)).first,
      )
      .didExceedMaxLines;

  Future<void> pumpIn(WidgetTester tester, double width, Widget child) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(width: width, child: child),
            ),
          ),
        ),
      );

  group('TruncatedText', () {
    testWidgets('fits: no tooltip', (tester) async {
      await pumpIn(tester, 400, const TruncatedText('Short'));
      await tester.pump();
      expect(tipOver(tester, find.text('Short')), isEmpty);
    });

    testWidgets('cut: the tooltip is the text in full', (tester) async {
      await pumpIn(tester, 120, const TruncatedText(long));
      await tester.pump();
      expect(cut(tester, find.text(long)), isTrue);
      expect(tipOver(tester, find.text(long)), long);
    });

    testWidgets('a given message stands in for the text', (tester) async {
      await pumpIn(
        tester,
        120,
        const TruncatedText(long, tooltip: '$long · Claude Code'),
      );
      await tester.pump();
      expect(tipOver(tester, find.text(long)), '$long · Claude Code');
    });

    testWidgets('it follows the width: cut, then whole again', (tester) async {
      // Room for the whole line in the test font's square glyphs.
      tester.view.physicalSize = const Size(2400, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpIn(tester, 120, const TruncatedText(long));
      await tester.pump();
      expect(tipOver(tester, find.text(long)), long);
      await pumpIn(tester, 2000, const TruncatedText(long));
      await tester.pump();
      expect(tipOver(tester, find.text(long)), isEmpty);
    });

    testWidgets('a long press shows it under a thumb', (tester) async {
      await pumpIn(tester, 120, const TruncatedText(long));
      await tester.pump();
      await tester.longPress(find.text(long));
      await tester.pump(const Duration(milliseconds: 100));
      // The text, and the tooltip saying it whole.
      expect(find.text(long), findsNWidgets(2));
      await tester.pumpAndSettle(const Duration(seconds: 2));
    });

    testWidgets('rich text: the tooltip is its plain words', (tester) async {
      await pumpIn(
        tester,
        120,
        const TruncatedText.rich(
          TextSpan(
            children: [
              TextSpan(text: long),
              TextSpan(text: '  karmashala · Windows'),
            ],
          ),
          textKey: ValueKey('rich'),
        ),
      );
      await tester.pump();
      expect(
        tipOver(tester, find.byKey(const ValueKey('rich'))),
        '$long  karmashala · Windows',
      );
    });
  });

  group('the tab strip', () {
    Widget chip(String label, {bool session = false}) => WorkbenchTabChip(
      selected: true,
      onTap: () {},
      label: label,
      tooltip: session
          ? tabTitleTooltip(label, 'Claude Code', where: 'Windows')
          : null,
    );

    testWidgets('a title that fits shows no tooltip', (tester) async {
      await pumpIn(tester, 240, chip('Short'));
      await tester.pump();
      expect(tipOver(tester, find.text('Short')), isEmpty);
    });

    testWidgets('a cut title shows it whole', (tester) async {
      await pumpIn(tester, 240, chip(long));
      await tester.pump();
      expect(cut(tester, find.text(long)), isTrue);
      expect(tipOver(tester, find.text(long)), long);
    });

    testWidgets('a session tab names its agent and machine, cut or not', (
      tester,
    ) async {
      await pumpIn(tester, 240, chip('Short', session: true));
      await tester.pump();
      expect(
        tipOver(tester, find.text('Short')),
        'Short · Claude Code · Windows',
      );
    });
  });

  group('the dashboard cards', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('ks-r66-titles'));
    tearDown(() => dir.deleteSync(recursive: true));

    for (final (size, phone) in const [
      (Size(1440, 900), false),
      (Size(360, 800), true),
      (Size(390, 844), true),
    ]) {
      testWidgets('${size.width.round()} px: a tooltip on each cut title, '
          'none on one that fits', (tester) async {
        await pumpMission(
          tester,
          fixture: MissionFixture.full(),
          prefsDir: dir,
          size: size,
          phone: phone,
        );
        await tester.pump();
        final titles = find.byWidgetPredicate(
          (w) =>
              w is Text &&
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith(
                'overview-card-title:',
              ),
        );
        expect(titles, findsWidgets);
        var anyCut = false;
        for (final element in titles.evaluate()) {
          final title = find.byWidget(element.widget);
          final isCut = cut(tester, title);
          anyCut |= isCut;
          final tip = tipOver(tester, title);
          expect(tip.isNotEmpty, isCut, reason: '${element.widget.key}');
          // Over every title is the shared helper, never a Text alone.
          expect(
            find.ancestor(of: title, matching: find.byType(TruncatedText)),
            findsOneWidget,
          );
        }
        // A phone cuts some of the fixture's titles: both halves are seen.
        if (phone) expect(anyCut, isTrue);
        await unmountMission(tester);
      });
    }
  });
}
