import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

/// **A line that names itself in full once it is cut**: [Text] with an
/// ellipsis, and a tooltip — hover on a desktop, long-press under a thumb —
/// only while the ellipsis is drawn. A title that fits says nothing more.
///
/// Answers intrinsic sizes as its text does, so it can stand where a parent
/// measures before it lays out.
class TruncatedText extends StatefulWidget {
  const TruncatedText(
    String this.data, {
    this.style,
    this.maxLines = 1,
    this.tooltip,
    this.triggerMode,
    this.textKey,
    this.always = false,
    super.key,
  }) : span = null;

  const TruncatedText.rich(
    InlineSpan this.span, {
    this.style,
    this.maxLines = 1,
    this.tooltip,
    this.triggerMode,
    this.textKey,
    this.always = false,
    super.key,
  }) : data = null;

  final String? data;
  final InlineSpan? span;
  final TextStyle? style;
  final int maxLines;

  /// What the tooltip says; the text itself when null.
  final String? tooltip;

  /// How a thumb asks for it. Null is a long press; a row whose own long
  /// press means something else passes [TooltipTriggerMode.manual].
  final TooltipTriggerMode? triggerMode;

  /// The inner [Text]'s key, for a caller that finds the text itself.
  final Key? textKey;

  /// Shows the tooltip whether or not the text is cut: for a [tooltip]
  /// that says more than the text does.
  final bool always;

  @override
  State<TruncatedText> createState() => _TruncatedTextState();
}

class _TruncatedTextState extends State<TruncatedText> {
  var _truncated = false;

  void _laidOut(bool truncated) {
    if (truncated == _truncated) return;
    // Known only after layout: the tooltip follows a frame later.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted && truncated != _truncated) {
        setState(() => _truncated = truncated);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final span = widget.span;
    final text = span == null
        ? Text(
            widget.data!,
            key: widget.textKey,
            maxLines: widget.maxLines,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          )
        : Text.rich(
            span,
            key: widget.textKey,
            maxLines: widget.maxLines,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          );
    final message = widget.tooltip ?? widget.data ?? span!.toPlainText();
    return _EllipsisProbe(
      onLaidOut: _laidOut,
      // An empty message draws the text alone: no hover, no long press.
      child: Tooltip(
        message: _truncated || widget.always ? message : '',
        triggerMode: widget.triggerMode,
        child: text,
      ),
    );
  }
}

class _EllipsisProbe extends SingleChildRenderObjectWidget {
  const _EllipsisProbe({required this.onLaidOut, required super.child});

  final ValueChanged<bool> onLaidOut;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderEllipsisProbe(onLaidOut);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderEllipsisProbe renderObject,
  ) => renderObject
    ..onLaidOut = onLaidOut
    // A new text may be cut where the old one was not.
    ..markNeedsLayout();
}

class _RenderEllipsisProbe extends RenderProxyBox {
  _RenderEllipsisProbe(this.onLaidOut);

  ValueChanged<bool> onLaidOut;

  @override
  void performLayout() {
    super.performLayout();
    final paragraph = _paragraphIn(this);
    if (paragraph != null) onLaidOut(paragraph.didExceedMaxLines);
  }

  static RenderParagraph? _paragraphIn(RenderObject node) {
    RenderParagraph? found;
    node.visitChildren((child) {
      found ??= child is RenderParagraph ? child : _paragraphIn(child);
    });
    return found;
  }
}
