import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design_tokens.dart';
import 'code_controller.dart';
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
    if (line != null && line != oldWidget.revealLine) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(line));
    }
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

    var longest = '';
    var longestRunes = 0;
    for (final line in text.split('\n')) {
      final runes = line.runes.length;
      if (runes > longestRunes) {
        longestRunes = runes;
        longest = line;
      }
    }

    _longestLineWidth = longest.isEmpty
        ? 0
        : _layout(longest, style, strut, scaler).width;
    _lineHeight = _layout('0', style, strut, scaler).height;

    final digits = widget.controller.lineCount.toString().length;
    _gutterWidth = widget.showLineNumbers
        ? _layout('0' * digits, style, strut, scaler).width + Insets.sm * 2
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
        return Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: _onKeyEvent,
          // No Scrollbar of our own: the scroll behaviour already draws the
          // vertical one on desktop, and two would paint over each other.
          child: SingleChildScrollView(
            controller: _vertical,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.showLineNumbers)
                  _Gutter(
                    lineCount: controller.lineCount,
                    width: _gutterWidth,
                    rowHeight: _lineHeight,
                    strut: strut,
                    style: codeStyle.copyWith(color: scheme.onSurfaceVariant),
                  ),
                SizedBox(
                  width: fieldWidth,
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
                        decoration: const InputDecoration.collapsed(
                          hintText: '',
                        ),
                        strutStyle: strut,
                        style: codeStyle,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Gutter extends StatelessWidget {
  const _Gutter({
    required this.lineCount,
    required this.width,
    required this.rowHeight,
    required this.strut,
    required this.style,
  });

  final int lineCount;
  final double width;
  final double rowHeight;
  final StrutStyle strut;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var line = 1; line <= lineCount; line++)
            SizedBox(
              height: rowHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
                child: Text(
                  '$line',
                  style: style,
                  strutStyle: strut,
                  textAlign: TextAlign.right,
                  maxLines: 1,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
