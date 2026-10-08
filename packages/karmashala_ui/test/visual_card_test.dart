import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/diagrams.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/transcript.dart';

/// Every kind `visualize` draws, in the frame drawn fences use; a spec that
/// cannot be drawn says why beside its source.
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

  final kinds = <String, (Object?, Finder)>{
    'chart': (
      {
        'type': 'bar',
        'data': [
          {'label': 'a', 'value': 1},
        ],
      },
      find.byType(SeriesChart),
    ),
    'table': (
      {
        'columns': ['a', 'b'],
        'rows': [
          [1, 'x'],
        ],
      },
      find.byType(DataTableView),
    ),
    'diagram': ({'source': 'graph TD\n  A --> B'}, find.byType(MermaidCanvas)),
    'image': (
      {'url': 'https://example.com/a.png'},
      find.byKey(const ValueKey('visual-image-load')),
    ),
    'metric': (
      [
        {'label': 'Tests', 'value': 812, 'delta': 12},
        {'label': 'Time', 'value': '4m 10s', 'better': 'down'},
      ],
      find.byKey(const ValueKey('visual-metrics')),
    ),
    'progress': (
      {
        'value': 3,
        'max': 8,
        'label': 'Build',
        'steps': [
          {'label': 'lint', 'status': 'done'},
          {'label': 'test', 'status': 'running'},
        ],
      },
      find.byKey(const ValueKey('visual-progress')),
    ),
    'tree': (
      {
        'a': [1, 2],
      },
      find.byType(JsonTreeView),
    ),
  };

  for (final MapEntry(key: kind, value: (data, drawn)) in kinds.entries) {
    testWidgets('$kind draws, titled, with Source and Copy', (tester) async {
      await show(tester, VisualCard(kind: kind, title: 'A $kind', data: data));
      expect(drawn, findsOneWidget);
      expect(find.text('A $kind'), findsOneWidget);
      expect(find.byKey(const ValueKey('fence-source')), findsOneWidget);
      expect(find.byTooltip('Copy source'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final width in const [360.0, 1440.0]) {
      for (final brightness in Brightness.values) {
        testWidgets('$kind fits at $width px, text ×1.6, ${brightness.name}', (
          tester,
        ) async {
          await show(
            tester,
            VisualCard(kind: kind, title: 'A $kind', data: data),
            width: width,
            textScale: 1.6,
            brightness: brightness,
          );
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets('progress shows its share and steps', (tester) async {
    await show(
      tester,
      VisualCard(kind: 'progress', data: kinds['progress']!.$1),
    );
    expect(find.text('3 of 8'), findsOneWidget);
    expect(find.text('lint'), findsOneWidget);
  });

  testWidgets('a web image waits to be asked for', (tester) async {
    await show(
      tester,
      const VisualCard(
        kind: 'image',
        data: {'url': 'https://example.com/a.png'},
      ),
    );
    expect(find.byType(Image), findsNothing);
    expect(find.text('Load image from example.com'), findsOneWidget);
  });

  testWidgets('a bad spec says why and shows its source', (tester) async {
    await show(
      tester,
      const VisualCard(kind: 'chart', data: {'type': 'pie', 'data': []}),
    );
    expect(find.byKey(const ValueKey('fence-failed')), findsOneWidget);
    expect(find.textContaining('"type" must be'), findsOneWidget);
    await show(tester, const VisualCard(kind: 'hologram', data: 1));
    expect(find.textContaining('not drawn by this version'), findsOneWidget);
  });

  testWidgets('Source shows the stored spec as JSON', (tester) async {
    await show(tester, const VisualCard(kind: 'tree', data: {'k': 1}));
    await tester.tap(find.byKey(const ValueKey('fence-source')));
    await tester.pump();
    expect(find.text('{\n  "k": 1\n}'), findsOneWidget);
  });
}
