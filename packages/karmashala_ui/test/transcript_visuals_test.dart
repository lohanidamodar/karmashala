import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/transcript.dart';

/// What a message draws rather than prints: charts, math, diffs, JSON trees,
/// coloured output and mermaid — each with its source a toggle away, and
/// what cannot be drawn shown as source with the reason.
void main() {
  Future<void> show(
    WidgetTester tester,
    String markdown, {
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
            body: SingleChildScrollView(child: MarkdownMessage(markdown)),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  String fence(String language, String body) => '```$language\n$body\n```';

  group('chart', () {
    testWidgets('a bar spec draws bars', (tester) async {
      await show(
        tester,
        fence(
          'chart',
          '{"type":"bar","title":"Suites","unit":"s",'
              '"data":[{"label":"app","value":420},{"label":"ui","value":11}]}',
        ),
      );
      expect(find.byType(BarChart), findsOneWidget);
      expect(find.text('Suites'), findsOneWidget);
    });

    testWidgets('a line spec draws a time series', (tester) async {
      await show(
        tester,
        fence(
          'chart',
          '{"type":"line","data":[{"x":"2026-10-01","y":3},'
              '{"x":"2026-10-03","y":7},{"x":"2026-10-05","y":5}]}',
        ),
      );
      expect(find.byType(TimeSeriesChart), findsOneWidget);
    });

    testWidgets('a bad spec shows why, and its source', (tester) async {
      await show(tester, fence('chart', '{"type":"pie","data":[]}'));
      expect(find.byKey(const ValueKey('fence-failed')), findsOneWidget);
      expect(find.textContaining('"type" must be'), findsOneWidget);
      expect(find.textContaining('"pie"'), findsOneWidget);
    });

    test('the spec parser names what is wrong', () {
      expect(
        () => parseChartSpec('{"type":"line","data":[{"x":"soon","y":1}]}'),
        throwsA(isA<FormatException>()),
      );
      final spec = parseChartSpec(
        '{"type":"bar","data":[{"label":"a","value":2}]}',
      );
      expect(spec.bars.single.value, 2);
    });
  });

  group('math', () {
    testWidgets('a math fence is drawn as an equation', (tester) async {
      await show(tester, fence('math', r'\frac{a}{b} = \sqrt{c}'));
      expect(find.byType(Math), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(r'$…$ is inline math and $$…$$ display math', (tester) async {
      await show(tester, r'Energy is $E = mc^2$ and $$\int_0^1 x\,dx$$ too.');
      expect(find.byType(Math), findsNWidgets(2));
    });

    testWidgets('money is not math', (tester) async {
      await show(tester, r'It costs $5 and $10, not $ 3 $.');
      expect(find.byType(Math), findsNothing);
      expect(
        find.textContaining(r'$5 and $10', findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets('TeX that will not parse stays as written', (tester) async {
      await show(tester, r'Broken $\frac{a$ here.');
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('a diff fence is a diff', (tester) async {
    await show(
      tester,
      fence('diff', '--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new'),
    );
    expect(find.byType(DiffText), findsOneWidget);
    expect(find.textContaining('+new', findRichText: true), findsOneWidget);
  });

  testWidgets('a JSON fence is a tree; broken JSON is source and why', (
    tester,
  ) async {
    await show(tester, fence('json', '{"name":"app","list":[1,2]}'));
    expect(find.byType(JsonTreeView), findsOneWidget);
    await show(tester, fence('json', '{nope'));
    expect(find.byKey(const ValueKey('fence-failed')), findsOneWidget);
  });

  testWidgets('escapes in any fence are drawn as colour', (tester) async {
    await show(tester, fence('', '\x1B[32mok\x1B[0m done'));
    expect(find.byType(AnsiText), findsOneWidget);
    expect(find.textContaining('[32m', findRichText: true), findsNothing);
  });

  testWidgets('Source shows the fence as written, and Visual draws it back', (
    tester,
  ) async {
    await show(tester, fence('json', '{"k":1}'));
    await tester.tap(find.byKey(const ValueKey('fence-source')));
    await tester.pump();
    expect(find.byType(JsonTreeView), findsNothing);
    expect(find.text('{"k":1}'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('fence-source')));
    await tester.pump();
    expect(find.byType(JsonTreeView), findsOneWidget);
  });

  testWidgets('a plain code fence stays code', (tester) async {
    await show(tester, fence('dart', 'void main() {}'));
    expect(find.byType(CodeBlock), findsOneWidget);
    expect(find.byType(VisualFenceBlock), findsNothing);
  });

  group('mermaid', () {
    testWidgets('zooms and pans on the whole screen', (tester) async {
      await show(tester, fence('mermaid', 'graph TD\n  A --> B'));
      await tester.tap(find.byKey(const ValueKey('mermaid-zoom')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mermaid-zoom-view')), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mermaid-zoom-view')), findsNothing);
    });

    testWidgets('a diagram that cannot be drawn shows why, and its source', (
      tester,
    ) async {
      await show(tester, fence('mermaid', 'graph TD\n  A -->'));
      expect(find.byKey(const ValueKey('mermaid-problem')), findsOneWidget);
      expect(find.byKey(const ValueKey('mermaid-source')), findsOneWidget);
      expect(find.byKey(const ValueKey('mermaid-zoom')), findsNothing);
    });
  });

  final everything = [
    fence(
      'chart',
      '{"type":"bar","data":[{"label":"a long label","value":3}]}',
    ),
    fence('math', r'\sum_{i=0}^{n} i = \frac{n(n+1)}{2}'),
    fence('diff', '-${'old ' * 40}\n+${'new ' * 40}'),
    fence('json', '{"a":{"b":{"c":[1,2,3]}}}'),
    fence('ansi', '\x1B[31m${'red ' * 40}\x1B[0m'),
    fence('mermaid', 'graph LR\n  A --> B --> C --> D'),
    r'Inline $a^2 + b^2 = c^2$ math.',
  ].join('\n\n');
  for (final width in const [360.0, 390.0, 1440.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('no overflow at $width px, text ×1.6, ${brightness.name}', (
        tester,
      ) async {
        await show(
          tester,
          everything,
          width: width,
          textScale: 1.6,
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}
