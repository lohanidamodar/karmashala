import 'package:flutter/material.dart';

import 'design_tokens.dart';

/// A label in a fixed column, [value] taking the rest of the row, and an
/// optional [trailing] action after it.
class LabeledValueRow extends StatelessWidget {
  const LabeledValueRow({
    required this.label,
    required this.value,
    this.trailing,
    this.labelWidth = defaultLabelWidth,
    this.labelStyle,
    this.padding = const EdgeInsets.only(bottom: Insets.xs),
    super.key,
  });

  /// Wide enough for "Verifier" and "Package" in `bodySmall` at 1x.
  static const defaultLabelWidth = 64.0;

  final String label;

  /// Must accept a bounded width: it sits in an `Expanded`.
  final Widget value;
  final Widget? trailing;
  final double labelWidth;

  /// Null draws the label in muted `bodySmall`.
  final TextStyle? labelStyle;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: labelWidth,
            child: Text(
              label,
              style:
                  labelStyle ??
                  theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          Expanded(child: value),
          ?trailing,
        ],
      ),
    );
  }
}
