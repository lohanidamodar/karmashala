import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/diagrams.dart';
import 'package:karmashala_ui/transcript.dart';

const _flow = 'graph TD\n  A[Start] --> B{Ok?}\n  B -->|yes| C[Done]';

void main() {
  Future<void> pump(WidgetTester tester, Widget child, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );
  }

  for (final size in const [Size(390, 844), Size(1440, 900)]) {
    testWidgets('a mermaid fence draws as a diagram at $size', (tester) async {
      await pump(
        tester,
        const MarkdownMessage('Here:\n\n```mermaid\n$_flow\n```\n\nThat is it.'),
        size,
      );
      expect(find.byType(MermaidBlock), findsOneWidget);
      expect(find.byKey(const ValueKey('mermaid-diagram')), findsOneWidget);
      expect(find.textContaining('Here:'), findsOneWidget);
      expect(find.textContaining('That is it.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the source stays one tap away, and copies whole', (
    tester,
  ) async {
    String? copied;
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
    await pump(tester, const MermaidBlock(_flow), const Size(800, 600));
    expect(find.byKey(const ValueKey('mermaid-source')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('mermaid-toggle')));
    await tester.pump();
    expect(find.byKey(const ValueKey('mermaid-source')), findsOneWidget);
    expect(find.textContaining('A[Start] --> B{Ok?}'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mermaid-copy')));
    expect(copied, _flow);
  });

  testWidgets('a sequence diagram draws too', (tester) async {
    await pump(
      tester,
      const MermaidBlock('sequenceDiagram\n  A->>B: hi\n  B-->>A: hey'),
      const Size(390, 844),
    );
    expect(find.byKey(const ValueKey('mermaid-diagram')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a type not drawn here says which, and shows the source', (
    tester,
  ) async {
    await pump(
      tester,
      const MermaidBlock('pie title Pets\n  "Dogs" : 3'),
      const Size(390, 844),
    );
    expect(find.textContaining('"pie" diagrams are not drawn'), findsOneWidget);
    expect(find.byKey(const ValueKey('mermaid-source')), findsOneWidget);
  });

  testWidgets('a source it cannot read says where, and shows it', (
    tester,
  ) async {
    await pump(
      tester,
      const MermaidBlock('graph TD\n  A -->'),
      const Size(390, 844),
    );
    expect(find.textContaining('line 2'), findsOneWidget);
    expect(find.byKey(const ValueKey('mermaid-source')), findsOneWidget);
  });

  test('fences are split only where a mermaid fence closes', () {
    expect(
      splitMermaidFences('a\n```mermaid\ngraph TD\nA-->B\n```\nb'),
      [
        (mermaid: false, text: 'a'),
        (mermaid: true, text: 'graph TD\nA-->B'),
        (mermaid: false, text: 'b'),
      ],
    );
    // Still streaming: stays markdown.
    expect(splitMermaidFences('a\n```mermaid\ngraph TD').single.mermaid, isFalse);
    // Inside another fence: that fence's text.
    final nested = splitMermaidFences(
      '````md\n```mermaid\ngraph TD\n```\n````',
    );
    expect(nested.single.mermaid, isFalse);
    // Other languages untouched.
    expect(
      splitMermaidFences('```dart\nvoid main() {}\n```').single.mermaid,
      isFalse,
    );
  });
}
