import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// The filled dot a coloured context wears — in its header's glyph column and
/// before its chip's label. Identity only: the row's status marks keep their
/// own glyphs, and this one never stands in for them.
class ContextHueDot extends StatelessWidget {
  const ContextHueDot({
    required this.hue,
    this.size = headerSize,
    this.label,
    super.key,
  });

  final ContextHue hue;
  final double size;

  /// What a screen reader hears; null leaves the dot silent, for a place that
  /// already names the colour.
  final String? label;

  /// In a header's [ExplorerRow.glyphSlot], under the 14px outline glyphs on
  /// project rows: a filled disc reads heavier than an outline of the same
  /// size, so it sits a step under them.
  static const headerSize = 10.0;

  /// Before a chip's 11px label.
  static const chipSize = 8.0;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final dot = SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: hue.of(brightness),
          shape: BoxShape.circle,
        ),
      ),
    );
    return label == null
        ? ExcludeSemantics(child: dot)
        : Semantics(label: label, child: dot);
  }
}
