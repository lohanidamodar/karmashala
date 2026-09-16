import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// The rounded frame round one turn. Unframed — no [fill], no [edge] — it adds
/// no padding either, so a turn that reads as the page itself sits flush.
class TranscriptTurnFrame extends StatelessWidget {
  const TranscriptTurnFrame({
    required this.child,
    this.fill,
    this.edge,
    this.radius = Radii.md,
    this.padding = const EdgeInsets.all(Insets.sm),
    this.clip = false,
    super.key,
  });

  final Widget child;
  final Color? fill;
  final Color? edge;
  final double radius;

  /// Inside the frame, when there is one to be inside.
  final EdgeInsetsGeometry padding;

  /// Clips [child] to the corners, for a body that paints to its own edge.
  final bool clip;

  bool get _framed => fill != null || edge != null;

  @override
  Widget build(BuildContext context) {
    if (!_framed) return child;
    final corners = BorderRadius.circular(radius);
    Widget body = Padding(padding: padding, child: child);
    if (clip) body = ClipRRect(borderRadius: corners, child: body);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: corners,
        border: edge == null ? null : Border.all(color: edge!),
      ),
      child: body,
    );
  }
}
