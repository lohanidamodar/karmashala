import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_core/visuals.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/diagrams.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/transcript.dart';

/// Round 53's polish of the drawn blocks: charts with axes, a legend and
/// bars that stay together; diffs tinted edge to edge with line numbers;
/// tables that sort and copy; mermaid that lights up a tapped node; JSON
/// trees that search, fold all and copy a path.
void main() {
  Future<void> show(
    WidgetTester tester,
    Widget child, {
    double width = 1200,
    double textScale = 1,
    Brightness brightness = Brightness.dark,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1600);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: brightness == Brightness.dark
            ? AppTheme.dark()
            : AppTheme.light(),
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: Padding(padding: const EdgeInsets.all(8), child: child),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  String? copied;
  setUp(() => copied = null);
  void catchClipboard(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
  }

  ChartVisual chart(Map<String, Object?> spec) =>
      parseVisualSpec(VisualKind.chart, spec) as ChartVisual;

  group('chart', () {
    final suites = chart({
      'type': 'bar',
      'unit': 's',
      'data': [
        {'label': 'app', 'value': 420},
        {'label': 'ui', 'value': 11},
        {'label': 'server', 'value': 95},
      ],
    });

    SeriesChartGeometry geometry(ChartVisual c, double width) =>
        SeriesChartGeometry(
          size: Size(width, 200),
          chart: c,
          axisStyle: const TextStyle(fontSize: 11),
          scaler: TextScaler.noScaling,
        );

    test('few bars on a wide card are wide and stay together', () {
      final g = geometry(suites, 1000);
      final (bar, _) = g.barWidths();
      expect(bar, greaterThanOrEqualTo(36));
      expect(g.plot.width, lessThanOrEqualTo(3 * 96 + 1));
    });

    test('many bars shrink but never vanish', () {
      final many = chart({
        'type': 'bar',
        'data': [for (var i = 0; i < 400; i++) i],
      });
      final (bar, _) = geometry(many, 360).barWidths();
      expect(bar, greaterThanOrEqualTo(1));
    });

    test('the value axis ticks at round steps from zero', () {
      final g = geometry(suites, 600);
      expect(g.yTicks.first, 0);
      expect(g.yTicks.last, greaterThanOrEqualTo(420));
      final step = g.yTicks[1] - g.yTicks[0];
      expect([1, 2, 5, 10, 20, 50, 100, 200, 500], contains(step));
      expect(g.yLabels, isNotEmpty);
      expect(g.xLabels.length, 3);
    });

    test('nice steps and numbers', () {
      expect(niceChartStep(420), 100);
      expect(niceChartStep(7), 2);
      expect(formatChartValue(1.5), '1.5');
      expect(formatChartValue(12000), '12k');
      expect(formatChartValue(0.256), '0.26');
    });

    testWidgets('one series has no legend; two have one, in theme colours', (
      tester,
    ) async {
      await show(tester, SeriesChart(chart: suites));
      expect(find.byKey(const ValueKey('series-chart-legend')), findsNothing);
      await show(
        tester,
        SeriesChart(
          chart: chart({
            'type': 'line',
            'series': [
              {
                'name': 'pass',
                'data': [
                  [1, 3],
                  [2, 4],
                ],
              },
              {
                'name': 'fail',
                'data': [
                  [1, 1],
                  [2, 0],
                ],
              },
            ],
          }),
        ),
      );
      expect(find.byKey(const ValueKey('series-chart-legend')), findsOneWidget);
      expect(find.text('pass'), findsOneWidget);
      expect(find.text('fail'), findsOneWidget);
      final context = tester.element(find.byType(SeriesChart));
      expect(
        ChartPalette.series(context, 0),
        Theme.of(context).colorScheme.primary,
      );
      expect(
        ChartPalette.series(context, 1),
        isNot(ChartPalette.series(context, 0)),
      );
    });

    testWidgets('a tap shows every value at that point', (tester) async {
      await show(tester, SeriesChart(chart: suites));
      final box = tester.getRect(
        find.byKey(const ValueKey('series-chart-paint')),
      );
      final g = geometry(suites, box.width);
      await tester.tapAt(box.topLeft + Offset(g.xAt(0), g.plot.center.dy));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('series-chart-tooltip')),
        findsOneWidget,
      );
      expect(find.text('420 s'), findsOneWidget);
      expect(find.text('app'), findsOneWidget);
    });

    testWidgets('empty and one-point charts draw', (tester) async {
      await show(
        tester,
        SeriesChart(chart: chart({'type': 'line', 'data': []})),
      );
      expect(find.text('No data yet'), findsOneWidget);
      await show(
        tester,
        SeriesChart(
          chart: chart({
            'type': 'line',
            'data': [
              {'x': '2026-10-08', 'y': 4},
            ],
          }),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('diff', () {
    const diff =
        '--- a/x.dart\n+++ b/x.dart\n@@ -12,3 +12,3 @@\n keep\n'
        '-old line\n+a much longer new line that runs well past the others\n'
        ' tail';

    test('lines are numbered from the hunk header', () {
      final lines = parseDiffText(diff);
      expect(lines[0].kind, DiffTextKind.meta);
      expect(lines[2].kind, DiffTextKind.hunk);
      expect(lines[3].oldNumber, 12);
      expect(lines[4].oldNumber, 13);
      expect(lines[5].newNumber, 13);
      expect(lines[6].oldNumber, 14);
      expect(lines[6].newNumber, 14);
    });

    testWidgets('every row is as wide as the widest, at least the box', (
      tester,
    ) async {
      await show(tester, const DiffText(diff), width: 1000);
      final rows = find.descendant(
        of: find.byKey(const ValueKey('diff-lines')),
        matching: find.byType(DecoratedBox),
      );
      final widths = {
        for (final e in rows.evaluate())
          (e.renderObject! as RenderBox).size.width,
      };
      expect(widths.length, 1);
      expect(widths.single, greaterThanOrEqualTo(1000 - 16));
      expect(find.text('12'), findsWidgets);
    });

    testWidgets('the fence has a wrap toggle', (tester) async {
      await show(
        tester,
        const MarkdownMessage('```diff\n$diff\n```'),
        width: 360,
      );
      expect(tester.widget<DiffText>(find.byType(DiffText)).wrap, isFalse);
      await tester.tap(find.byKey(const ValueKey('diff-wrap')));
      await tester.pump();
      expect(tester.widget<DiffText>(find.byType(DiffText)).wrap, isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  group('table', () {
    const columns = ['name', 'tests'];
    final rows = [
      ['ui', 120],
      ['app', 2200],
      ['server', 9],
    ];

    testWidgets('a header tap sorts up, again down, then back', (tester) async {
      await show(tester, DataTableView(columns: columns, rows: rows));
      double top(String text) => tester.getTopLeft(find.text(text)).dy;
      await tester.tap(find.byKey(const ValueKey('table-sort-1')));
      await tester.pump();
      expect(top('9'), lessThan(top('120')));
      expect(top('120'), lessThan(top('2200')));
      await tester.tap(find.byKey(const ValueKey('table-sort-1')));
      await tester.pump();
      expect(top('2200'), lessThan(top('9')));
      await tester.tap(find.byKey(const ValueKey('table-sort-1')));
      await tester.pump();
      expect(top('120'), lessThan(top('2200')));
      expect(top('2200'), lessThan(top('9')));
    });

    testWidgets('copies as CSV and as Markdown', (tester) async {
      catchClipboard(tester);
      await show(
        tester,
        DataTableView(
          columns: const ['a', 'b'],
          rows: const [
            ['x, y', 'say "hi"'],
            ['p|q', null],
          ],
        ),
      );
      await tester.tap(find.byKey(const ValueKey('table-copy-csv')));
      await tester.pump();
      expect(copied, 'a,b\n"x, y","say ""hi"""\np|q,');
      await tester.tap(find.byKey(const ValueKey('table-copy-md')));
      await tester.pump();
      expect(
        copied,
        '| a | b |\n| --- | --- |\n| x, y | say "hi" |\n| p\\|q |  |',
      );
    });

    testWidgets('a long table scrolls under a header that stays', (
      tester,
    ) async {
      await show(
        tester,
        DataTableView(
          columns: const ['i'],
          rows: [
            for (var i = 0; i < 200; i++) [i],
          ],
        ),
      );
      final header = tester.getTopLeft(
        find.byKey(const ValueKey('table-header')),
      );
      await tester.drag(
        find.byKey(const ValueKey('table-rows')),
        const Offset(0, -300),
      );
      await tester.pump();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('table-header'))),
        header,
      );
      expect(find.text('0'), findsNothing);
    });

    testWidgets('a wide table scrolls sideways inside its box', (tester) async {
      await show(
        tester,
        DataTableView(
          columns: [for (var c = 0; c < 20; c++) 'column $c'],
          rows: [
            [for (var c = 0; c < 20; c++) 'value $c'],
          ],
        ),
        width: 360,
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(Scrollbar), findsOneWidget);
    });
  });

  group('mermaid', () {
    Future<void> tapNode(WidgetTester tester, String id) async {
      final paint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byKey(const ValueKey('mermaid-canvas')),
          matching: find.byType(CustomPaint),
        ),
      );
      final picture = (paint.painter! as MermaidPainter).picture;
      final rect = tester.getRect(find.byKey(const ValueKey('mermaid-canvas')));
      final scale = rect.width / picture.size.width;
      for (var y = 0.0; y < picture.size.height; y += 3) {
        for (var x = 0.0; x < picture.size.width; x += 3) {
          if (picture.hit(Offset(x, y)) == id) {
            await tester.tapAt(rect.topLeft + Offset(x, y) * scale);
            await tester.pump();
            return;
          }
        }
      }
      fail('no point hits $id');
    }

    MermaidPainter painter(WidgetTester tester) =>
        tester
                .widget<CustomPaint>(
                  find.descendant(
                    of: find.byKey(const ValueKey('mermaid-canvas')),
                    matching: find.byType(CustomPaint),
                  ),
                )
                .painter!
            as MermaidPainter;

    testWidgets('tapping a node lights up its edges; again lets go', (
      tester,
    ) async {
      await show(
        tester,
        const MermaidBlock('graph TD\n  A --> B\n  B --> C\n  A --> C'),
      );
      await tapNode(tester, 'A');
      expect(painter(tester).selected, 'A');
      expect(painter(tester).picture.linksOf('A'), {0, 2});
      await tapNode(tester, 'A');
      expect(painter(tester).selected, isNull);
    });

    testWidgets('a sequence participant lights up its messages', (
      tester,
    ) async {
      await show(
        tester,
        const MermaidBlock(
          'sequenceDiagram\n  A->>B: hi\n  B->>C: on\n  C-->>A: back',
        ),
      );
      await tapNode(tester, 'B');
      expect(painter(tester).picture.linksOf('B'), {0, 1});
    });

    testWidgets('fits the width; a big one gets zoom controls', (tester) async {
      final wide =
          'graph LR\n  ${[for (var i = 0; i < 12; i++) 'N$i[step number $i]'].join(' --> ')}';
      await show(tester, MermaidBlock(wide), width: 360);
      final canvas = tester.getRect(
        find.byKey(const ValueKey('mermaid-canvas')),
      );
      // Shrunk to fit as far as it reads, then scrolled.
      final natural = painter(tester).picture.size.width;
      expect(canvas.width, closeTo(natural * MermaidCanvas.minFitScale, 1));
      expect(find.byKey(const ValueKey('mermaid-zoom-in')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mermaid-zoom-in')));
      await tester.pump();
      expect(
        tester.getRect(find.byKey(const ValueKey('mermaid-canvas'))).width,
        greaterThan(canvas.width),
      );
      await tester.tap(find.byKey(const ValueKey('mermaid-zoom-fit')));
      await tester.pump();
      expect(find.text('Fit'), findsOneWidget);

      await show(
        tester,
        const MermaidBlock('graph TD\n  A --> B'),
        width: 1200,
      );
      expect(find.byKey(const ValueKey('mermaid-zoom-in')), findsNothing);
    });
  });

  group('json tree', () {
    const value = {
      'name': 'app',
      'deps': {
        'flutter': {'sdk': 'flutter'},
        'riverpod': '^3.0.0',
      },
      'list': [1, 2, 3],
    };

    testWidgets('expand all and collapse all', (tester) async {
      await show(tester, const JsonTreeView(value));
      expect(find.textContaining('sdk', findRichText: true), findsNothing);
      await tester.tap(find.byKey(const ValueKey('json-expand-all')));
      await tester.pump();
      expect(find.textContaining('sdk', findRichText: true), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('json-collapse-all')));
      await tester.pump();
      expect(find.textContaining('name', findRichText: true), findsNothing);
    });

    testWidgets('search opens what matches and counts it', (tester) async {
      await show(tester, const JsonTreeView(value));
      await tester.enterText(find.byType(TextField), 'sdk');
      await tester.pump();
      expect(find.byKey(const ValueKey('json-match-count')), findsOneWidget);
      expect(find.text('1 match'), findsOneWidget);
      expect(find.textContaining('sdk', findRichText: true), findsWidgets);
    });

    testWidgets('a tapped row shows its path, which copies', (tester) async {
      catchClipboard(tester);
      await show(tester, const JsonTreeView(value, openDepth: 3));
      await tester.tap(find.byKey(const ValueKey(r'json-row-$.deps.riverpod')));
      await tester.pump();
      expect(find.text(r'$.deps.riverpod'), findsOneWidget);
      await tester.tap(find.byTooltip('Copy path'));
      await tester.pump();
      expect(copied, r'$.deps.riverpod');
      expect(jsonChildPath(r'$', 'odd key'), r'$["odd key"]');
      expect(jsonChildPath(r'$.list', 2), r'$.list[2]');
    });
  });

  final parts = <String, Widget>{
    'chart': SeriesChart(
      chart: chart({
        'type': 'bar',
        'series': [
          {
            'name': 'a series with a long name',
            'data': [
              {'label': 'a fairly long category', 'value': 3},
              {'label': 'b', 'value': 1200000},
            ],
          },
          {
            'name': 'b',
            'data': [
              {'label': 'b', 'value': -4},
            ],
          },
        ],
      }),
    ),
    'diff': const DiffText('@@ -1,2 +1,2 @@\n-old\n+new\n same'),
    'table': DataTableView(
      columns: [for (var c = 0; c < 6; c++) 'a long column name $c'],
      rows: [
        [for (var c = 0; c < 6; c++) 'cell $c with words'],
      ],
    ),
    'mermaid': const MermaidBlock(
      'graph LR\n  A[one] --> B[two] --> C[three] --> D[four]',
    ),
    'json': const JsonTreeView({
      'a': {
        'b': [1, 2],
      },
    }),
  };
  for (final MapEntry(key: name, value: part) in parts.entries) {
    for (final width in const [360.0, 1440.0]) {
      for (final brightness in Brightness.values) {
        testWidgets(
          '$name: no overflow at $width px, text ×1.6, ${brightness.name}',
          (tester) async {
            await show(
              tester,
              part,
              width: width,
              textScale: 1.6,
              brightness: brightness,
            );
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
