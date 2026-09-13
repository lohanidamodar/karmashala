import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'code_lines.dart';
import 'code_spans.dart';

/// Above this many characters a buffer is drawn in plain mono: highlighting is
/// O(file) and runs per keystroke. The *open* cap is the editor's and larger.
const int kHighlightSizeCap = 256 * 1024;

/// A [TextEditingController] that paints its buffer with `highlight`, and owns
/// the indentation a code buffer expects from Enter and Tab.
class CodeEditingController extends TextEditingController {
  CodeEditingController({super.text, this.language});

  /// The `highlight` language id, or null for plain text.
  String? language;

  /// The palette [buildTextSpan] paints with. The field sets this each build,
  /// so a theme change recolours without a new controller.
  Map<String, TextStyle> highlightTheme = const <String, TextStyle>{};

  /// False draws plain mono — set by the field above [kHighlightSizeCap].
  bool highlightingEnabled = true;

  /// Text a Tab inserts, and the unit Shift+Tab removes.
  static const String indent = '  ';

  int? _lineCount;
  String? _countedText;

  /// Lines in the buffer (never 0 — an empty buffer is one line). Counted by
  /// code unit and memoised: a caret blink asks for this too.
  int get lineCount {
    final source = text;
    if (_countedText == source) return _lineCount!;
    var lines = 1;
    for (var i = 0; i < source.length; i++) {
      if (isCodeLineBreak(source.codeUnitAt(i))) lines++;
    }
    _countedText = source;
    return _lineCount = lines;
  }

  static final RegExp _leading = RegExp(r'^[ \t]*');

  TextSpan? _memo;
  String? _memoText;
  String? _memoLanguage;
  Map<String, TextStyle>? _memoTheme;
  bool? _memoEnabled;
  TextStyle? _memoStyle;

  /// Rebuilt only when the text, language, palette or style actually changed:
  /// a caret blink and every selection change come through here too, and
  /// re-parsing a large file on each would stall the field.
  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final memo = _memo;
    if (memo != null &&
        _memoText == text &&
        _memoLanguage == language &&
        _memoEnabled == highlightingEnabled &&
        _memoStyle == style &&
        identical(_memoTheme, highlightTheme)) {
      return memo;
    }

    final span = (!highlightingEnabled || language == null)
        ? TextSpan(text: text, style: style)
        : highlightedCode(
            text,
            language: language,
            theme: highlightTheme,
            base: style,
          );

    _memo = span;
    _memoText = text;
    _memoLanguage = language;
    _memoEnabled = highlightingEnabled;
    _memoStyle = style;
    _memoTheme = highlightTheme;
    return span;
  }

  /// Handles Enter (continue the previous line's indent, and add one level
  /// after an opening brace), Tab and Shift+Tab. Returns true when it consumed
  /// the key; the field then does nothing else with it.
  bool handleKey(LogicalKeyboardKey key, {required bool shift}) {
    if (!selection.isValid) return false;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      return _newline();
    }
    if (key == LogicalKeyboardKey.tab) {
      if (shift) return _outdent();
      _replace(selection.start, selection.end, indent);
      return true;
    }
    return false;
  }

  bool _newline() {
    final start = selection.start;
    final lineStart = _lineStartAt(start);
    final head = text.substring(lineStart, start);
    final lead = _leading.firstMatch(head)?.group(0) ?? '';
    final deeper = head.trimRight().endsWith('{');
    _replace(start, selection.end, '\n$lead${deeper ? indent : ''}');
    return true;
  }

  bool _outdent() {
    final lineStart = _lineStartAt(selection.start);
    final lead = _leading.firstMatch(text.substring(lineStart))?.group(0) ?? '';
    if (lead.isEmpty) return false;

    final removed = lead.length < indent.length ? lead.length : indent.length;
    final next = text.replaceRange(lineStart, lineStart + removed, '');
    int shifted(int offset) => offset <= lineStart
        ? offset
        : (offset - removed).clamp(lineStart, next.length);
    value = TextEditingValue(
      text: next,
      selection: selection.copyWith(
        baseOffset: shifted(selection.baseOffset),
        extentOffset: shifted(selection.extentOffset),
      ),
    );
    return true;
  }

  int _lineStartAt(int offset) =>
      offset == 0 ? 0 : text.lastIndexOf('\n', offset - 1) + 1;

  void _replace(int start, int end, String insertion) {
    value = TextEditingValue(
      text: text.replaceRange(start, end, insertion),
      selection: TextSelection.collapsed(offset: start + insertion.length),
    );
  }
}
