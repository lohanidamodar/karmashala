import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design_tokens.dart';
import 'code_controller.dart';
import 'code_gutter.dart';
import 'code_lines.dart';
import 'code_theme.dart';

/// The strut the field is laid out with. One gutter row is the line box that
/// strut actually produced, measured rather than multiplied out: the engine's
/// answer is not `fontSize * height` to the pixel, and half a pixel per line is
/// a whole line lost within one screenful.
const double kCodeLineHeight = 1.4;

/// A code buffer with a line-number gutter: one vertical viewport over both, so
/// the numbers cannot scroll away from the lines they count, and a horizontal
/// one under the text alone, because code is never soft-wrapped.
class CodeField extends StatefulWidget {
  const CodeField({
    required this.controller,
    this.focusNode,
    this.readOnly = false,
    this.fontSize = 13,
    this.showLineNumbers = true,
    this.onSave,
    this.revealLine,
    super.key,
  });

  final CodeEditingController controller;
  final FocusNode? focusNode;
  final bool readOnly;
  final double fontSize;
  final bool showLineNumbers;

  /// Ctrl+S (Cmd+S on macOS). Null leaves the chord alone.
  final VoidCallback? onSave;

  /// A 1-based line to scroll into view when it changes. Null scrolls nothing.
  final int? revealLine;

  @override
  State<CodeField> createState() => _CodeFieldState();
}

class _CodeFieldState extends State<CodeField> {
  final ScrollController _vertical = ScrollController();
  final ScrollController _horizontal = ScrollController();
  FocusNode? _ownedFocus;

  String _measuredText = '';
  double _measuredFontSize = 0;
  double _longestLineWidth = 0;
  double _gutterWidth = 0;
  double _lineHeight = 0;
  bool _stale = true;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    // A field mounted with a line already asked for never reaches
    // [didUpdateWidget], and that is the ordinary case: the caller sets the
    // line in the same turn it opens the file.
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

    _longestLineWidth = longestEnd == longestStart
        ? 0
        : _layout(
            text.substring(longestStart, longestEnd),
            style,
            strut,
            scaler,
          ).width;
    _lineHeight = _layout('0', style, strut, scaler).height;

    _gutterWidth = widget.showLineNumbers
        ? CodeGutter.widthFor(widget.controller.lineCount, style, scaler)
        : 0;
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
    _vertical.jumpTo(
      ((line - 1) * _lineHeight).clamp(0.0, _vertical.position.maxScrollExtent),
    );
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
        (Platform.isMacOS
            ? keyboard.isMetaPressed
            : keyboard.isControlPressed)) {
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
    // Explicit letterSpacing: the field merges its style over the text theme's
    // body style, so a theme that spaces prose would widen every line past the
    // width measured here and wrap the code that must not wrap.
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
                child: SingleChildScrollView(
                  controller: _horizontal,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: math.max(fieldWidth, _longestLineWidth + Insets.lg),
                    child: TextField(
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
                      // InputDecorationTheme is filled and bordered, and a
                      // code surface drawn as a text box reads as a form.
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
                    ),
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
              // Outside the scroll view on purpose: it is painted at the
              // viewport and scrolled by the controller, so its cost is the
              // rows on screen rather than the rows in the file.
              if (widget.showLineNumbers)
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
