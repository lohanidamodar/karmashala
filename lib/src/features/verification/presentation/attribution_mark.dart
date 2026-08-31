import 'package:flutter/material.dart';

import '../../../app/theme/design_tokens.dart';
import '../domain/verdict_attribution.dart';

/// The one way this app says who graded something.
///
/// Three surfaces show a verdict — the verification pane, a fan-out
/// candidate's chip, and a comparison's outcome — and each of them mapped the
/// three states to a colour on its own. Three copies of that mapping are three
/// chances for "self" to be the reassuring colour on one surface and the
/// warning colour on another, which is precisely the disagreement attribution
/// exists to prevent. The words come from [VerdictAttribution]; the colour
/// comes from here; nothing else decides either.
class AttributionMark extends StatelessWidget {
  const AttributionMark({required this.attribution, super.key});

  final VerdictAttribution attribution;

  /// Self-verified takes the attention colour rather than the healthy one: a
  /// candidate's own account of itself is the thing worth a second look. "Not
  /// recorded" is neutral, because it is a gap rather than a finding.
  static Color colourOf(BuildContext context, VerdictAttribution attribution) {
    final semantic = SemanticColors.of(context);
    return switch (attribution) {
      VerdictAttribution.author => semantic.attention,
      VerdictAttribution.independent => semantic.idle,
      VerdictAttribution.notRecorded => semantic.neutral,
    };
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    message: attribution.label,
    child: Text(
      // Never conditional on the state: an unrecorded verifier that renders
      // nothing reads as "verified" to anyone scanning the row.
      attribution.shortLabel,
      maxLines: 1,
      style: Theme.of(
        context,
      ).textTheme.labelSmall?.copyWith(color: colourOf(context, attribution)),
    ),
  );
}
