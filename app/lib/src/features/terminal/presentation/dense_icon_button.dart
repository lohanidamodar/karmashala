import 'package:flutter/material.dart';
import 'package:karmashala_ui/tokens.dart';

/// An icon action inside a chip or a dense row: a square sized from the row it
/// sits in, instead of a minimum picked per call site.
class DenseIconButton extends StatelessWidget {
  const DenseIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.extent = inRow,
    this.color,
    super.key,
  });

  /// In a chip on a [Chrome.paneStrip] row, which leaves room for a rule.
  static const inPaneStrip = Chrome.paneStrip - 6;

  /// In a chip on a [Chrome.tabStrip] row.
  static const inTabStrip = Chrome.tabStrip - 10;

  /// Beside a line of text — a diff line, a pane's floating handle.
  static const inRow = Chrome.row - 4;

  final String tooltip;

  /// The glyph, or any widget in its place — a status dot.
  final Widget icon;
  final VoidCallback? onPressed;
  final double extent;
  final Color? color;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    visualDensity: VisualDensity.compact,
    constraints: BoxConstraints.tightFor(width: extent, height: extent),
    padding: EdgeInsets.zero,
    // A chip's glyph sits beside its label; a row's action has more room.
    iconSize: extent < inRow ? Chrome.iconSmall : Chrome.iconAction,
    color: color,
    icon: icon,
    onPressed: onPressed,
  );
}
