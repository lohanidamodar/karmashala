import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import 'code_field.dart' show kCodeLineHeight;
import 'code_gutter.dart';
import 'code_lines.dart';

/// A file too big to edit, drawn read-only **one screenful at a time**.
///
/// [CodeField] hands its whole buffer to a `TextField`, which lays it out as a
/// single paragraph — linear in the file, on every keystroke. This draws the
/// lines on screen and nothing else, so opening costs the same at ten lines and
/// ten million. Plain mono on purpose: colouring needs the whole file parsed.
class CodeViewer extends StatefulWidget {
  const CodeViewer({
    required this.text,
    this.fontSize = 13,
    this.showLineNumbers = true,
    this.revealLine,
    super.key,
  });

  final String text;
  final double fontSize;
  final bool showLineNumbers;

  /// A 1-based line to put on screen when it changes.
  final int? revealLine;

  @override
  State<CodeViewer> createState() => _CodeViewerState();
}

class _CodeViewerState extends State<CodeViewer> {
  final ScrollController _vertical = ScrollController();
  final ScrollController _horizontal = ScrollController();

  /// Line start offsets, so a row is a `substring` rather than an entry in a
  /// second copy of the file.
  List<int> _starts = const [0];
  String _splitText = '';

  double _rowHeight = 0;
  double _longestLineWidth = 0;
  double _gutterWidth = 0;
  String _measuredText = '';
  double _measuredFontSize = 0;

  /// How wide a line is laid out before the rest of it is simply clipped. A
  /// minified bundle is one line of several megabytes, and laying that out is
  /// the one cost a per-row viewer can still hit.
  static const double _maxLineWidth = 40000;

  @override
  void initState() {
    super.initState();
    if (widget.revealLine case final line?) _revealAfterFrame(line);
  }

  @override
  void didUpdateWidget(CodeViewer old) {
    super.didUpdateWidget(old);
    final line = widget.revealLine;
    if (line != null && line != old.revealLine) _revealAfterFrame(line);
  }

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  void _revealAfterFrame(int line) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_vertical.hasClients || _rowHeight <= 0) return;
      _vertical.jumpTo(
        ((line - 1) * _rowHeight).clamp(
          0.0,
          _vertical.position.maxScrollExtent,
        ),
      );
    });
  }

  /// Where every line begins. One scan over the code units — no `split`, which
  /// would hold a second copy of the whole file as a list of strings.
  void _split() {
    if (_splitText == widget.text) return;
    _splitText = widget.text;
    final starts = <int>[0];
    for (var i = 0; i < _splitText.length; i++) {
      if (isCodeLineBreak(_splitText.codeUnitAt(i))) starts.add(i + 1);
    }
    _starts = starts;
  }

  String _lineAt(int index) {
    final start = _starts[index];
    final end = index + 1 < _starts.length
        ? _starts[index + 1] - 1
        : _splitText.length;
    // A trailing `\r` is the other half of a CRLF the buffer kept.
    final stop = end > start && _splitText.codeUnitAt(end - 1) == 0x0D
        ? end - 1
        : end;
    return _splitText.substring(start, math.max(start, stop));
  }

  void _measure(TextStyle style, StrutStyle strut, TextScaler scaler) {
    final fontSize = scaler.scale(widget.fontSize);
    if (_measuredText == widget.text && _measuredFontSize == fontSize) return;
    _measuredText = widget.text;
    _measuredFontSize = fontSize;

    var longest = 0;
    var longestIndex = 0;
    for (var i = 0; i < _starts.length; i++) {
      final end = i + 1 < _starts.length
          ? _starts[i + 1] - 1
          : _splitText.length;
      if (end - _starts[i] > longest) {
        longest = end - _starts[i];
        longestIndex = i;
      }
    }

    _rowHeight = _layout('0', style, strut, scaler).height;
    _longestLineWidth = longest == 0
        ? 0
        : math.min(
            _maxLineWidth,
            _layout(_lineAt(longestIndex), style, strut, scaler).width,
          );
    _gutterWidth = widget.showLineNumbers
        ? CodeGutter.widthFor(_starts.length, style, scaler)
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final strut = StrutStyle(
      fontFamily: kMonoFamily,
      fontSize: widget.fontSize,
      height: kCodeLineHeight,
      forceStrutHeight: true,
    );
    final codeStyle = TextStyle(
      fontFamily: kMonoFamily,
      fontSize: widget.fontSize,
      letterSpacing: 0,
      color: scheme.onSurface,
    );
    _split();
    _measure(codeStyle, strut, MediaQuery.textScalerOf(context));

    return LayoutBuilder(
      builder: (context, constraints) {
        final bodyWidth = math.max(0.0, constraints.maxWidth - _gutterWidth);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.showLineNumbers)
              CodeGutter(
                lineCount: _starts.length,
                rowHeight: _rowHeight,
                scroll: _vertical,
                width: _gutterWidth,
                style: codeStyle.copyWith(color: scheme.onSurfaceVariant),
              ),
            SizedBox(
              width: bodyWidth,
              child: SingleChildScrollView(
                controller: _horizontal,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: math.max(bodyWidth, _longestLineWidth + Insets.lg),
                  child: SelectionArea(
                    child: ListView.builder(
                      controller: _vertical,
                      // Fixed, so the list never measures a row it is not
                      // drawing and the scrollbar is right from the first frame.
                      itemExtent: _rowHeight,
                      itemCount: _starts.length,
                      itemBuilder: (context, index) => Text(
                        _lineAt(index),
                        style: codeStyle,
                        strutStyle: strut,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.clip,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
