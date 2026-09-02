import 'package:flutter/material.dart';

import '../theme/design_tokens.dart';

/// A [Chrome.dot]-wide coloured dot that **cannot be unlabelled**.
///
/// Six places drew this by hand, and the one with the most to say — the fan-out
/// candidate dot — carried four distinct states in colour alone: no glyph, no
/// tooltip, no semantics. Two files away the session verdict mark states the
/// house rule outright: *"A glyph as well as a colour … state is never carried
/// by colour alone."*
///
/// So [label] is required, and required by construction rather than by review:
/// a dot with nothing to say cannot be written. It says what the colour
/// *means* — "failed", "3 waiting" — never what it looks like, and it reaches
/// the semantics tree, which is what Narrator reads.
class StatusDot extends StatelessWidget {
  const StatusDot({
    required this.color,
    required this.label,
    this.tooltip,
    this.ring,
    super.key,
  }) : assert(label != '', 'a status dot says what its colour means');

  /// From [SemanticColors], never a raw hue.
  final Color color;

  /// What this colour means, in words.
  final String label;

  /// A hover message, where the dot is the only thing under the pointer. Left
  /// null where something above it already has one — a nested tooltip hides
  /// the outer one, which is a loss, not a gain.
  final String? tooltip;

  /// The ground the dot is punched out of, when it sits on something it would
  /// otherwise disappear into — a badge over a rail glyph. Drawn inside the
  /// [Chrome.dot] box, so the dot's footprint never changes.
  final Color? ring;

  @override
  Widget build(BuildContext context) {
    final dot = Semantics(
      container: true,
      label: label,
      child: Container(
        width: Chrome.dot,
        height: Chrome.dot,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: ring == null ? null : Border.all(color: ring!),
        ),
      ),
    );
    return tooltip == null ? dot : Tooltip(message: tooltip!, child: dot);
  }
}
