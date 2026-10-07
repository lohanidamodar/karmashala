import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../code/code_spans.dart';
import '../code/code_theme.dart';
import '../design_tokens.dart';
import 'code_block.dart' show highlightLanguage;

/// Source with line numbers in a box of at most [maxHeight], scrolled so
/// [focusLine] (1-based) is in sight and marked. Scrolls both ways inside the
/// box, never the page.
class NumberedCodeView extends StatefulWidget {
  const NumberedCodeView({
    required this.source,
    this.language,
    this.focusLine,
    this.maxHeight = 360,
    super.key,
  });

  final String source;
  final String? language;
  final int? focusLine;
  final double maxHeight;

  @override
  State<NumberedCodeView> createState() => _NumberedCodeViewState();
}

class _NumberedCodeViewState extends State<NumberedCodeView> {
  final _scroll = ScrollController();

  /// The line last scrolled to, so a rebuild does not pull the reader back.
  int? _jumpedTo;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  double _lineHeight(TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: '0', style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final height = painter.preferredLineHeight;
    painter.dispose();
    return height;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mono = MonoStyles.small.copyWith(color: scheme.onSurface);
    final lines = widget.source.split('\n');
    final lineHeight = _lineHeight(mono);
    final focus = widget.focusLine;
    final focusIndex = focus == null || focus < 1 || focus > lines.length
        ? null
        : focus - 1;
    if (focusIndex != null && focusIndex != _jumpedTo) {
      _jumpedTo = focusIndex;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        final target = math.max(0.0, (focusIndex - 3) * lineHeight);
        _scroll.jumpTo(math.min(target, _scroll.position.maxScrollExtent));
      });
    }
    final gutterWidth = '${lines.length}'.length;
    final numbers = [
      for (var i = 1; i <= lines.length; i++) '$i'.padLeft(gutterWidth),
    ].join('\n');
    final code = Text.rich(
      highlightedCode(
        widget.source,
        language: highlightLanguage(widget.language),
        theme: codeHighlightTheme(theme.brightness),
        base: mono,
      ),
      softWrap: false,
    );
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: widget.maxHeight),
      child: SingleChildScrollView(
        controller: _scroll,
        child: Stack(
          children: [
            if (focusIndex != null)
              Positioned(
                left: 0,
                right: 0,
                top: Insets.xs + focusIndex * lineHeight,
                height: lineHeight,
                child: ColoredBox(
                  key: const ValueKey('numbered-code-focus'),
                  color: StateLayers.selected(scheme),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Insets.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectionContainer.disabled(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Insets.sm,
                      ),
                      child: Text(
                        numbers,
                        style: mono.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: code,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
