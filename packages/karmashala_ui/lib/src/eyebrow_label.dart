import 'package:flutter/material.dart';

/// The small spaced label over a section or a field — written in any case and
/// drawn uppercase in the theme's `labelSmall`, the chrome eyebrow.
class EyebrowLabel extends StatelessWidget {
  const EyebrowLabel(
    this.text, {
    this.color,
    this.maxLines,
    this.padding = EdgeInsets.zero,
    super.key,
  });

  final String text;

  /// Null keeps the theme's muted ink.
  final Color? color;

  /// Null wraps; a cap ellipsises, for a label sharing its row.
  final int? maxLines;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;
    final label = Text(
      text.toUpperCase(),
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
      style: color == null ? style : style?.copyWith(color: color),
    );
    return padding == EdgeInsets.zero
        ? label
        : Padding(padding: padding, child: label);
  }
}
