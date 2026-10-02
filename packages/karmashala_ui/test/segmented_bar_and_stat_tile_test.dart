import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/theme.dart';

import 'support/layout_probe.dart';

/// A whole split into parts, and a headline number. What a caller relies on: a
/// sliver still shows, an unrecorded part takes no room and says so in words,
/// tiles reflow by width and text size, and both name themselves to a reader.
void main() {
  group('segmentSpans', () {
    test('widths follow the values, with gaps between shown parts', () {
      final spans = segmentSpans([100, 300], 402, gap: 2, minWidth: 0);
      expect(spans[0]!.left, 0);
      expect(spans[0]!.width, closeTo(100, 1e-9));
      expect(spans[1]!.left, closeTo(102, 1e-9));
      expect(spans[1]!.width, closeTo(300, 1e-9));
    });

    test('a zero or unrecorded part gets no width and no gap', () {
      final spans = segmentSpans([null, 50, 0, 50], 102, gap: 2, minWidth: 0);
      expect(spans[0], isNull);
      expect(spans[2], isNull);
      expect(spans[1]!.width, closeTo(50, 1e-9));
      expect(spans[3]!.left, closeTo(52, 1e-9));
    });

    test('a sliver is drawn at the minimum, taken from the wide parts', () {
      final spans = segmentSpans([1, 99999], 202, gap: 2, minWidth: 3);
      expect(spans[0]!.width, 3);
      expect(spans[1]!.width, closeTo(197, 1e-9));
      final end = spans[1]!.left + spans[1]!.width;
      expect(end, closeTo(202, 1e-9), reason: 'the parts still fill the bar');
    });

    test('nothing to split, or no room, draws nothing', () {
      expect(segmentSpans([null, 0], 100), [null, null]);
      expect(segmentSpans([5, 5], 0), [null, null]);
      expect(segmentSpans(const [], 100), isEmpty);
    });

    test(
      'never lays out wider than the bar, even when every part is small',
      () {
        final spans = segmentSpans([1, 1, 1, 1], 8, gap: 2, minWidth: 3);
        final last = spans.last!;
        expect(last.left + last.width, lessThanOrEqualTo(8 + 1e-9));
      },
    );

    test('the painter never throws at any size', () {
      for (final size in const [
        Size.zero,
        Size(1, 1),
        Size(4, 10),
        Size(640, 10),
      ]) {
        for (final values in const [
          <int?>[],
          <int?>[null],
          <int?>[0, 0],
          <int?>[1, 1000000, null, 7],
        ]) {
          final recorder = ui.PictureRecorder();
          SegmentedBarPainter(
            values: values,
            colors: [for (final _ in values) Colors.teal],
            track: Colors.grey,
          ).paint(Canvas(recorder), size);
          recorder.endRecording().dispose();
        }
      }
    });
  });

  group('statTileColumns', () {
    test('as many as fit, evened out so no tile sits alone', () {
      expect(statTileColumns(620, 5), 5);
      expect(statTileColumns(480, 5), 3, reason: '4 fit; 3 + 2, not 4 + 1');
      expect(statTileColumns(300, 5), 2);
      expect(statTileColumns(200, 5), 1);
      expect(statTileColumns(900, 3), 3, reason: 'never more than there are');
      expect(statTileColumns(620, 0), 1);
    });

    test('bigger text needs wider tiles', () {
      expect(
        statTileColumns(600, 5, textScaler: const TextScaler.linear(1.3)),
        lessThan(statTileColumns(600, 5)),
      );
    });

    test('an unbounded width puts everything on one row', () {
      expect(statTileColumns(double.infinity, 4), 4);
    });

    test('a cap holds a row to it, still evened out', () {
      expect(statTileColumns(620, 5, maxColumns: 2), 2);
      expect(statTileColumns(900, 9, maxColumns: 4), 3, reason: '3 + 3 + 3');
      expect(statTileColumns(200, 5, maxColumns: 4), 1);
    });
  });

  group('as widgets', () {
    const segments = [
      BarSegment(
        label: 'Input',
        value: 5332,
        color: Colors.teal,
        valueLabel: '5.3k',
        detail: '<1%',
      ),
      BarSegment(label: 'Cache write', value: null, color: Colors.grey),
      BarSegment(
        label: 'Cache read',
        value: 44952107,
        color: Colors.blueGrey,
        valueLabel: '45M',
        detail: '97%',
      ),
    ];

    List<Widget> tiles() => const [
      StatTile(label: 'Total tokens', value: '46.3M', caption: '46,343,099'),
      StatTile(label: 'Turns', value: '213'),
      StatTile(label: 'Tool calls', value: null),
      StatTile(label: 'Replies', value: '3,294'),
      StatTile(label: 'Elapsed', value: '2h 11m', caption: 'first to last'),
    ];

    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      for (final width in [120.0, 320.0, 620.0]) {
        for (final scale in sweepScales) {
          testWidgets(
            'lay out at ${width}px, ${theme.brightness.name}, ${scale}x',
            (tester) async {
              final overflows = await pumpInBox(
                tester,
                width: width,
                theme: theme,
                textScale: scale,
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      StatTileGrid(tiles: tiles()),
                      const SegmentedBar(
                        segments: segments,
                        semanticsLabel: 'tokens',
                      ),
                      const ChartLegend(segments: segments),
                    ],
                  ),
                ),
              );
              expect(overflows, isEmpty);
              expect(tester.takeException(), isNull);
            },
          );
        }
      }
    }

    testWidgets('the grid reflows with its width', (tester) async {
      Future<int> rowsAt(double width) async {
        await pumpInBox(
          tester,
          width: width,
          child: StatTileGrid(tiles: tiles()),
        );
        final tops = {
          for (final e in find.byType(StatTile).evaluate())
            tester.getTopLeft(find.byWidget(e.widget)).dy,
        };
        return tops.length;
      }

      expect(await rowsAt(620), 1);
      expect(await rowsAt(320), 3);
      expect(await rowsAt(160), 5);
    });

    testWidgets('an unrecorded value is words, never a figure', (tester) async {
      await pumpInBox(
        tester,
        width: 400,
        child: const Column(
          children: [
            StatTile(label: 'Tool calls', value: null),
            ChartLegend(segments: segments),
          ],
        ),
      );
      expect(
        find.textContaining('not recorded', findRichText: true),
        findsNWidgets(2),
      );
      expect(find.text('0'), findsNothing);
    });

    testWidgets('both name themselves to a screen reader', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpInBox(
        tester,
        width: 600,
        child: const Column(
          children: [
            StatTile(label: 'Total tokens', value: '46.3M', caption: 'exact'),
            StatTile(label: 'Tool calls', value: null),
            SegmentedBar(
              segments: segments,
              semanticsLabel: 'Tokens: 97% cache read',
            ),
            ChartLegend(segments: segments),
          ],
        ),
      );
      expect(
        find.bySemanticsLabel('Total tokens, 46.3M, exact'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Tool calls, not recorded'), findsOneWidget);
      expect(find.bySemanticsLabel('Tokens: 97% cache read'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('Cache read.*45M.*97%')),
        findsOneWidget,
      );
      semantics.dispose();
    });
  });
}
