import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/code.dart';

/// Benchmark — NOT part of `flutter test`'s default run. Run it on demand:
///
///   flutter test tool/benchmark/code_field_bench.dart
///
/// The question it exists to answer: **how big a file can the editor open
/// before it stops being an editor?** The caps in `source_document.dart` are
/// set from this, not from a guess.
///
/// Read it as a curve at 1k / 5k / 20k / 50k / 100k lines. Three costs scale
/// differently and the slopes are what matter:
///
///  * **open** — build + layout of the whole field. The gutter used to be a
///    `Column` of four widgets a line, so this was linear in the file.
///  * **keystroke** — one text change, re-laid out. The `TextField` lays the
///    whole buffer out as one paragraph, so this is the ceiling.
///  * **highlight** — one `highlight.parse` of the buffer.
///
/// Then the same question of [CodeViewer], which draws only the rows on screen:
/// its open and scroll costs must be **flat** in the line count.
///
/// Wall-clock figures are machine-dependent and are printed, not asserted —
/// same contract as `tool/benchmark/paint_bench.dart`.
void main() {
  const sizes = [1000, 5000, 20000, 50000];
  const viewerSizes = [1000, 50000, 200000, 1000000];

  /// Dart-shaped lines, so the highlighter has real work rather than prose.
  String source(int lines) => List.generate(
    lines,
    (i) => "  final value$i = compute($i, 'label-$i'); // line $i",
  ).join('\n');

  Future<void> pumpField(
    WidgetTester tester,
    CodeEditingController controller,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CodeField(controller: controller)),
      ),
    );
  }

  setUpAll(() {
    // ignore: avoid_print
    print('lines | bytes | open ms | keystroke ms | highlight ms');
  });

  for (final lines in sizes) {
    testWidgets('$lines lines', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final text = source(lines);
      final controller = CodeEditingController(text: text, language: 'dart');
      // Highlighting measured on its own below; the field turns it off above
      // its own cap anyway, so the open/keystroke figures are the plain ones.
      controller.highlightingEnabled = false;
      addTearDown(controller.dispose);

      final open = Stopwatch()..start();
      await pumpField(tester, controller);
      open.stop();

      final keystroke = Stopwatch()..start();
      controller.value = controller.value.copyWith(
        text: '// edited\n$text',
        selection: const TextSelection.collapsed(offset: 10),
      );
      await tester.pump();
      keystroke.stop();

      // One parse of the same buffer, through the controller's own path.
      final highlighted = CodeEditingController(text: text, language: 'dart')
        ..highlightingEnabled = true;
      addTearDown(highlighted.dispose);
      final parse = Stopwatch()..start();
      highlighted.buildTextSpan(
        context: tester.element(find.byType(CodeField)),
        withComposing: false,
      );
      parse.stop();

      // ignore: avoid_print
      print(
        '$lines | ${text.length} | ${open.elapsedMilliseconds} | '
        '${keystroke.elapsedMilliseconds} | ${parse.elapsedMilliseconds}',
      );
    });
  }

  // A minified bundle is one line of megabytes: flat in the line *count* says
  // nothing about it, and the viewer used to shape the whole line to measure
  // its width. This must be flat in the length too.
  for (final units in const [100000, 400000, 1600000]) {
    testWidgets('viewer: one line of $units', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final open = Stopwatch()..start();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: CodeViewer(text: 'x' * units)),
        ),
      );
      open.stop();

      // ignore: avoid_print
      print('viewer 1 line x $units | ${open.elapsedMilliseconds}');
    });
  }

  // The read-only viewer draws only the rows on screen, so its cost must be
  // flat in the file. Read these as a *slope*: a number that grows with the
  // line count means something is still touching the whole buffer per frame.
  for (final lines in viewerSizes) {
    testWidgets('viewer: $lines lines', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final text = source(lines);
      final open = Stopwatch()..start();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: CodeViewer(text: text)),
        ),
      );
      open.stop();

      // A scroll into the middle of the file: the frame that has to build a
      // screenful of rows it has never drawn.
      final scroll = Stopwatch()..start();
      await tester.drag(find.byType(CodeViewer), const Offset(0, -4000));
      await tester.pump();
      scroll.stop();

      // ignore: avoid_print
      print(
        'viewer $lines | ${text.length} | ${open.elapsedMilliseconds} | '
        '${scroll.elapsedMilliseconds}',
      );
    });
  }
}
