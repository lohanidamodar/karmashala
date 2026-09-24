import 'package:flutter/material.dart';

import 'package:karmashala_ui/tokens.dart';
import '../domain/verdict_attribution.dart';

/// The one way this app says who graded something. Three surfaces show a
/// verdict, and three copies of the state-to-colour mapping are three chances
/// to disagree: the words come from [VerdictAttribution], the colour from here.
class AttributionMark extends StatelessWidget {
  const AttributionMark({required this.attribution, super.key});

  final VerdictAttribution attribution;

  /// Self-verified takes the attention colour, not the healthy one: an account
  /// of itself is worth a second look. "Not recorded" is neutral — a gap.
  static Color colourOf(BuildContext context, VerdictAttribution attribution) {
    final semantic = SemanticColors.of(context);
    return switch (attribution) {
      VerdictAttribution.author => semantic.attention,
      VerdictAttribution.independent || VerdictAttribution.app => semantic.idle,
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
      overflow: TextOverflow.ellipsis,
      style: Theme.of(
        context,
      ).textTheme.labelSmall?.copyWith(color: colourOf(context, attribution)),
    ),
  );
}
