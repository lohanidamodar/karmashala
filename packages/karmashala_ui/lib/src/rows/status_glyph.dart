import 'package:flutter/material.dart';

import 'package:agent_cli/descriptors.dart';

import '../design_tokens.dart';
import '../stepped_ring.dart';
import 'agent_status_appearance.dart';

export '../stepped_ring.dart';

/// The glyph for an agent's status: [agentStatusAppearance]'s icon, except
/// that "working" is a stepped spinner rather than a still half-circle.
class StatusGlyph extends StatelessWidget {
  const StatusGlyph({
    required this.status,
    required this.size,
    this.color,
    this.semanticLabel,
    super.key,
  });

  final AgentActivityStatus status;
  final double size;

  /// Null takes the status's own semantic colour.
  final Color? color;

  /// As [Icon.semanticLabel]: null leaves the words to something nearby.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final appearance = agentStatusAppearance(status);
    final colour = color ?? appearance.colour(SemanticColors.of(context));
    if (status == AgentActivityStatus.working) {
      return WorkingSpinner(
        size: size,
        color: colour,
        semanticLabel: semanticLabel,
      );
    }
    return Icon(
      appearance.icon,
      size: size,
      color: colour,
      semanticLabel: semanticLabel,
    );
  }
}

/// A 1.5px [SteppedRing] in a glyph's place, for a session that is working.
class WorkingSpinner extends StatelessWidget {
  const WorkingSpinner({
    required this.size,
    required this.color,
    this.semanticLabel,
    super.key,
  });

  final double size;
  final Color color;
  final String? semanticLabel;

  /// Thinner than the house spinner: this one stands among 11px glyphs.
  static const strokeWidth = 1.5;

  /// About where a Phosphor circle sits in its em square, so the spinner reads
  /// as the same size as the glyphs beside it.
  static const inset = 0.8;

  @override
  Widget build(BuildContext context) {
    // Laid out like [Icon], so swapping one for the other moves nothing.
    return Semantics(
      label: semanticLabel,
      child: ExcludeSemantics(
        child: SteppedRing(
          size: size,
          color: color,
          stroke: strokeWidth,
          inset: inset,
        ),
      ),
    );
  }
}
