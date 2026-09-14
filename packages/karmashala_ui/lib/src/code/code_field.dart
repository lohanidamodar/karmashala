import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design_tokens.dart';
import 'code_controller.dart';
import 'code_gutter.dart';
import 'code_lines.dart';
import 'code_theme.dart';

/// The strut the field is laid out with. A gutter row is the line box it
/// produced, measured rather than multiplied out.
const double kCodeLineHeight = 1.4;

/// A code buffer with a line-number gutter: one vertical viewport over both, so
/// the numbers cannot scroll away from the lines they count.
class CodeField extends StatefulWidget {
  const CodeField({
    required this.controller,
    this.focusNode,
    this.readOnly = false,
    this.fontSize = 13,
    this.showLineNumbers = true,
    this.wrap = false,
    this.onSave,
    this.revealLine,
    super.key,
  });

  final CodeEditingController controller;
  final FocusNode? focusNode;
  final bool readOnly;
  final double fontSize;
  final bool showLineNumbers;

  /// Soft-wrap long lines instead of scrolling sideways.
  ///
  /// Line numbers are suppressed while this is on: the gutter paints number
  /// *n* at *n* x row height, so one wrapped line puts every number below it
  /// against the wrong row. A gutter that lies is worse than none.
  final bool wrap;

  /// Ctrl+S (Cmd+S on macOS). Null leaves the chord alone.
  final VoidCallback? onSave;

  /// A 1-based line to scroll into view when it changes. Null scrolls nothing.
  final int? revealLine;

  @override
  State<CodeField> createState() => _CodeFieldState();
}

class _CodeFieldState extends State<CodeField> {
  /// Numbers are drawn only when they can be trusted — see [CodeField.wrap].
  bool get _showsGutter => widget.showLineNumbers && !widget.wrap;

  final ScrollController _vertical = ScrollController();
  final ScrollController _horizontal = ScrollController();
  FocusNode? _ownedFocus;

  String _measuredText = '';
  double _measuredFontSize = 0;
  double _longestLineWidth = 0;
  double _gutterWidth = 0;
  double _lineHeight = 0;
  bool _stale = true;

  /// The last measured text style, strut, scaler and field width — kept only
  /// so a reveal can lay the text out the way the field just did.
  TextStyle? _codeStyle;
  StrutStyle? _codeStrut;
  TextScaler _codeScaler = TextScaler.noScaling;
  double _fieldWidth = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    // A field mounted with a line already asked for never reaches
    // [didUpdateWidget], and that is the ordinary case.
    if (widget.revealLine case final line?) _revealAfterFrame(line);
  }

  @override
  void didUpdateWidget(CodeField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
    if (!identical(oldWidget.controller, widget.controller) ||
        oldWidget.fontSize != widget.fontSize ||
        oldWidget.showLineNumbers != widget.showLineNumbers) {
      _stale = true;
    }
    final line = widget.revealLine;
    if (line != null && line != oldWidget.revealLine) _revealAfterFrame(line);
  }

  void _revealAfterFrame(int line) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reveal(line);
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _vertical.dispose();
    _horizontal.dispose();
    _ownedFocus?.dispose();
    super.dispose();
  }

  FocusNode get _focusNode =>
      widget.focusNode ?? (_ownedFocus ??= FocusNode(debugLabel: 'CodeField'));

  /// Selection changes and caret blinks notify too; only new text is worth a
  /// re-measure of the widest line.
  void _onControllerChanged() {
    if (widget.controller.text == _measuredText) return;
    setState(() => _stale = true);
  }

  void _measure(TextStyle style, StrutStyle strut, TextScaler scaler) {
    final text = widget.controller.text;
    final fontSize = scaler.scale(widget.fontSize);
    if (!_stale && text == _measuredText && fontSize == _measuredFontSize) {
      return;
    }
    _stale = false;
    _measuredText = text;
    _measuredFontSize = fontSize;

    // One scan over the code units rather than `split` + `runes`.
    var longestStart = 0;
    var longestEnd = 0;
    var start = 0;
    for (var i = 0; i <= text.length; i++) {
      if (i != text.length && !isCodeLineBreak(text.codeUnitAt(i))) continue;
      if (i - start > longestEnd - longestStart) {
        longestStart = start;
        longestEnd = i;
      }
      start = i + 1;
    }

    _longestLineWidth = _widthOfLongest(
      text,
      longestStart,
      longestEnd,
      style,
      strut,
      scaler,
    );
    _lineHeight = _layout('0', style, strut, scaler).height;

    _codeStyle = style;
    _codeStrut = strut;
    _codeScaler = scaler;

    _gutterWidth = _showsGutter
        ? CodeGutter.widthFor(widget.controller.lineCount, style, scaler)
        : 0;
  }

  /// The widest line, shaped to at most [kMaxLineUnitsLaidOut] code units and
  /// extrapolated past that — exact in a monospace face, and never a wrap.
  double _widthOfLongest(
    String text,
    int start,
    int end,
    TextStyle style,
    StrutStyle strut,
    TextScaler scaler,
  ) {
    if (end == start) return 0;
    final sample = clipLineForLayout(text, start, end);
    final width = _layout(sample, style, strut, scaler).width;
    return sample.length >= end - start
        ? width
        : width * (end - start) / sample.length;
  }

  Size _layout(
    String line,
    TextStyle style,
    StrutStyle strut,
    TextScaler scaler,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: line, style: style),
      strutStyle: strut,
      textScaler: scaler,
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final size = painter.size;
    painter.dispose();
    return size;
  }

  void _reveal(int line) {
    if (!mounted || !_vertical.hasClients) return;
    final top = widget.wrap
        ? _wrappedTopOf(line)
        : (line - 1) * _lineHeight;
    _vertical.jumpTo(top.clamp(0.0, _vertical.position.maxScrollExtent));
  }

  /// Where line [line] begins once everything above it has wrapped.
  ///
  /// `(line - 1) * _lineHeight` is only true while one line is one row, so a
  /// wrapped buffer needs the text above the target actually laid out. Nothing
  /// exposes the field's own line metrics, so this lays it out again at the
  /// same width and strut. One layout on a jump nobody makes in a loop, and
  /// being a few pixels short only scrolls slightly short — it states nothing.
  double _wrappedTopOf(int line) {
    final style = _codeStyle;
    final strut = _codeStrut;
    if (style == null || strut == null || _fieldWidth <= 0 || line <= 1) {
      return 0;
    }
    final text = widget.controller.text;
    var end = 0;
    for (var i = 1; i < line; i++) {
      final next = text.indexOf('\n', end);
      if (next < 0) return 0;
      end = next + 1;
    }
    if (end == 0) return 0;
    final painter = TextPainter(
      text: TextSpan(text: text.substring(0, end), style: style),
      strutStyle: strut,
      textScaler: _codeScaler,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: _fieldWidth);
    final height = painter.height;
    painter.dispose();
    return height;
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final onSave = widget.onSave;
    if (onSave != null &&
        event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyS &&
        _saveChord(keyboard)) {
      onSave();
      return KeyEventResult.handled;
    }
    if (widget.readOnly) return KeyEventResult.ignored;
    final consumed = widget.controller.handleKey(
      event.logicalKey,
      shift: keyboard.isShiftPressed,
    );
    return consumed ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  /// Exactly Ctrl+S (Cmd+S on macOS): Ctrl+Shift+S is a different chord and
  /// belongs to whatever the embedder binds it to.
  bool _saveChord(HardwareKeyboard keyboard) {
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    if (keyboard.isShiftPressed || keyboard.isAltPressed) return false;
    return mac
        ? keyboard.isMetaPressed && !keyboard.isControlPressed
        : keyboard.isControlPressed && !keyboard.isMetaPressed;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final controller = widget.controller;
    controller.highlightTheme = codeHighlightTheme(theme.brightness);
    // One-way: a caller that turned highlighting off keeps it off.
    if (controller.text.length > kHighlightSizeCap) {
      controller.highlightingEnabled = false;
    }

    final strut = StrutStyle(
      fontFamily: kMonoFamily,
      fontSize: widget.fontSize,
      height: kCodeLineHeight,
      forceStrutHeight: true,
    );
    // Explicit letterSpacing: a theme that spaces prose would widen every line
    // past the width measured here and wrap the code that must not wrap.
    final codeStyle = TextStyle(
      fontFamily: kMonoFamily,
      fontSize: widget.fontSize,
      letterSpacing: 0,
      color: scheme.onSurface,
    );
    _measure(codeStyle, strut, MediaQuery.textScalerOf(context));

    return LayoutBuilder(
      builder: (context, constraints) {
        final fieldWidth = math.max(0.0, constraints.maxWidth - _gutterWidth);
        _fieldWidth = fieldWidth;
        // Lifted out so wrapping can drop the horizontal viewport around it
        // without duplicating the field configuration.
        final field = TextField(
          controller: controller,
          focusNode: _focusNode,
          readOnly: widget.readOnly,
          maxLines: null,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.multiline,
          cursorColor: scheme.primary,
          scrollPadding: EdgeInsets.zero,
          // The two viewports above own scrolling; the field's
          // own would fight them for the drag.
          scrollPhysics: const NeverScrollableScrollPhysics(),
          // Spelled out rather than `collapsed`: the app's
          // decoration theme draws a code surface as a form.
          decoration: const InputDecoration(
            isCollapsed: true,
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: EdgeInsets.zero,
          ),
          strutStyle: strut,
          style: codeStyle,
        );

        final code = GestureDetector(
          behavior: HitTestBehavior.opaque,
          // The buffer rarely fills the pane; a click in the space under the
          // last line should still put the caret in the file.
          onTap: _focusNode.requestFocus,
          // No Scrollbar of our own: the scroll behaviour already draws the
          // vertical one on desktop, and two would paint over each other.
          child: SingleChildScrollView(
            controller: _vertical,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              // Loose, so the field is as tall as its own text and the space
              // under the last line is empty rather than a stretched field.
              child: Align(
                alignment: Alignment.topLeft,
                child: widget.wrap
                    ? SizedBox(width: fieldWidth, child: field)
                    : SingleChildScrollView(
                        controller: _horizontal,
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: math.max(
                            fieldWidth,
                            _longestLineWidth + Insets.lg,
                          ),
                          child: field,
                        ),
                      ),
              ),
            ),
          ),
        );
        return Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: _onKeyEvent,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Outside the scroll view on purpose: painted at the viewport,
              // so its cost is the rows on screen and not those in the file.
              if (_showsGutter)
                CodeGutter(
                  lineCount: controller.lineCount,
                  rowHeight: _lineHeight,
                  scroll: _vertical,
                  width: _gutterWidth,
                  style: codeStyle.copyWith(color: scheme.onSurfaceVariant),
                ),
              SizedBox(width: fieldWidth, child: code),
            ],
          ),
        );
      },
    );
  }
}
