import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:highlight/highlight.dart' show highlight;
import 'package:karmashala_ui/code.dart';

/// **What a code buffer owes its reader, below the widget.**
///
/// The span walk, the memo that keeps a caret blink from re-parsing the file,
/// and the indentation rules — all of it is reachable without pumping a field,
/// which is why the field routes its keys through [CodeEditingController].
void main() {
  final theme = codeHighlightTheme(Brightness.dark);

  /// Every leaf of [span], in painting order.
  List<TextSpan> leaves(TextSpan span) {
    final found = <TextSpan>[];
    void walk(InlineSpan node) {
      if (node is! TextSpan) return;
      if (node.text != null) found.add(node);
      for (final child in node.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    }

    walk(span);
    return found;
  }

  /// Every span under [span] including the branches, which is where a class
  /// name that wraps other nodes puts its colour.
  List<TextSpan> allSpans(TextSpan span) {
    final found = <TextSpan>[];
    void walk(InlineSpan node) {
      if (node is! TextSpan) return;
      found.add(node);
      for (final child in node.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    }

    walk(span);
    return found;
  }

  String plainText(TextSpan span) => leaves(span).map((s) => s.text).join();

  group('spans', () {
    test('a dart snippet is split and styled', () {
      final nodes = highlight.parse('class A {}', language: 'dart').nodes!;
      final spans = highlightSpans(nodes, theme);

      final root = TextSpan(children: spans);
      expect(leaves(root).length, greaterThan(1));
      expect(leaves(root).map((s) => s.text).join(), 'class A {}');
      // `keyword` and `title` are branches over their text, so the colour is
      // on the span that wraps a leaf, not on the leaf.
      expect(
        allSpans(root).where((s) => s.style == theme['keyword']),
        isNotEmpty,
      );
    });

    test('an unknown language falls through as one plain span', () {
      final span = highlightedCode(
        'not a language at all',
        language: 'karmashala-script',
        theme: theme,
      );

      final parts = leaves(span);
      expect(parts, hasLength(1));
      expect(parts.single.style, isNull);
      expect(parts.single.text, 'not a language at all');
    });

    test('the base style is the root, and the text survives the walk', () {
      const base = TextStyle(fontSize: 11);
      final span = highlightedCode(
        'void main() {}\n// two lines\n',
        language: 'dart',
        theme: theme,
        base: base,
      );

      expect(span.style, base);
      expect(plainText(span), 'void main() {}\n// two lines\n');
    });
  });

  group('the buffer', () {
    test('an empty buffer is one line', () {
      expect(CodeEditingController().lineCount, 1);
      expect(CodeEditingController(text: 'a\nb\nc').lineCount, 3);
      expect(CodeEditingController(text: 'a\n').lineCount, 2);
    });

    test('the same text is the same span object, new text is not', () {
      final controller = CodeEditingController(text: 'var a = 1;')
        ..language = 'dart'
        ..highlightTheme = theme;

      final first = controller.buildSpan();
      expect(controller.buildSpan(), same(first));

      controller.text = 'var a = 2;';
      final second = controller.buildSpan();
      expect(second, isNot(same(first)));
      expect(plainText(second), 'var a = 2;');
    });

    test('the memo notices the palette and the highlighting switch', () {
      final controller = CodeEditingController(text: 'var a = 1;')
        ..language = 'dart'
        ..highlightTheme = theme;

      final coloured = controller.buildSpan();
      controller.highlightTheme = codeHighlightTheme(Brightness.light);
      expect(controller.buildSpan(), isNot(same(coloured)));

      controller.highlightingEnabled = false;
      final plain = controller.buildSpan();
      expect(leaves(plain), hasLength(1));
      expect(plain.text, 'var a = 1;');
    });

    test('a null language is drawn plain', () {
      final controller = CodeEditingController(text: '{"a": 1}')
        ..highlightTheme = theme;

      expect(controller.buildSpan().text, '{"a": 1}');
    });
  });

  group('a line the engine is asked to shape', () {
    test('a short line is handed over whole', () {
      expect(clipLineForLayout('final a = 1;'), 'final a = 1;');
      expect(clipLineForLayout('abcdef', 2, 4), 'cd');
      expect(clipLineForLayout(''), '');
    });

    test('a minified line is cut to the cap', () {
      final line = 'x' * (kMaxLineUnitsLaidOut * 3);

      expect(clipLineForLayout(line), hasLength(kMaxLineUnitsLaidOut));
      expect(clipLineForLayout('.$line', 1), hasLength(kMaxLineUnitsLaidOut));
    });

    test('the cut never lands inside a surrogate pair', () {
      // An emoji straddling the cap would otherwise leave half of itself,
      // which lays out as a replacement glyph of its own width.
      final line = '${'x' * (kMaxLineUnitsLaidOut - 1)}😀 rest';

      final clipped = clipLineForLayout(line);
      expect(clipped, hasLength(kMaxLineUnitsLaidOut - 1));
      expect(clipped.codeUnits.last, lessThan(0xD800));
    });
  });

  group('indentation', () {
    CodeEditingController at(String text, int offset) =>
        CodeEditingController(text: text)
          ..selection = TextSelection.collapsed(offset: offset);

    test('Enter continues the line it left', () {
      final controller = at('  foo', 5);

      expect(
        controller.handleKey(LogicalKeyboardKey.enter, shift: false),
        isTrue,
      );
      expect(controller.text, '  foo\n  ');
      expect(controller.selection.baseOffset, 8);
    });

    test('Enter after an opening brace adds a level', () {
      final controller = at('  if (x) {', 10);

      expect(
        controller.handleKey(LogicalKeyboardKey.enter, shift: false),
        isTrue,
      );
      expect(controller.text, '  if (x) {\n    ');
      expect(controller.selection.baseOffset, 15);
    });

    test('Enter on an unindented line starts one', () {
      final controller = at('main() {}', 9);

      controller.handleKey(LogicalKeyboardKey.enter, shift: false);
      expect(controller.text, 'main() {}\n');
    });

    test('Tab inserts one indent at the caret', () {
      final controller = at('ab', 1);

      expect(
        controller.handleKey(LogicalKeyboardKey.tab, shift: false),
        isTrue,
      );
      expect(controller.text, 'a${CodeEditingController.indent}b');
      expect(controller.selection.baseOffset, 3);
    });

    test('Tab replaces a selection', () {
      final controller = CodeEditingController(text: 'abcd')
        ..selection = const TextSelection(baseOffset: 1, extentOffset: 3);

      controller.handleKey(LogicalKeyboardKey.tab, shift: false);
      expect(controller.text, 'a  d');
    });

    test('Shift+Tab removes one level and keeps the caret on its text', () {
      final controller = at('    foo', 7);

      expect(controller.handleKey(LogicalKeyboardKey.tab, shift: true), isTrue);
      expect(controller.text, '  foo');
      expect(controller.selection.baseOffset, 5);
    });

    test('Shift+Tab outdents the caret line, not the buffer', () {
      final controller = at('a\n  b\n  c', 5);

      controller.handleKey(LogicalKeyboardKey.tab, shift: true);
      expect(controller.text, 'a\nb\n  c');
    });

    test('Shift+Tab at column 0 does nothing and does not consume the key', () {
      final controller = at('foo', 0);

      expect(
        controller.handleKey(LogicalKeyboardKey.tab, shift: true),
        isFalse,
      );
      expect(controller.text, 'foo');
    });

    test('any other key is left alone', () {
      final controller = at('foo', 3);

      expect(
        controller.handleKey(LogicalKeyboardKey.keyA, shift: false),
        isFalse,
      );
      expect(
        controller.handleKey(LogicalKeyboardKey.escape, shift: true),
        isFalse,
      );
      expect(controller.text, 'foo');
    });

    test('a buffer nobody has focused refuses every key', () {
      final controller = CodeEditingController(text: 'foo');

      expect(controller.selection.isValid, isFalse);
      expect(
        controller.handleKey(LogicalKeyboardKey.tab, shift: false),
        isFalse,
      );
      expect(controller.text, 'foo');
    });
  });
}

extension on CodeEditingController {
  /// [buildTextSpan] without a widget tree: the context is declared required
  /// and never read, so an unmounted element stands in for one.
  TextSpan buildSpan() => buildTextSpan(
    context: StatelessElement(const _Unused()),
    style: const TextStyle(fontSize: 13),
    withComposing: false,
  );
}

class _Unused extends StatelessWidget {
  const _Unused();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
