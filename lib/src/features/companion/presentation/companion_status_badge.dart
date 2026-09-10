import 'package:flutter/material.dart';

import '../../../app/theme/design_tokens.dart';
import 'package:agent_cli/descriptors.dart';
import '../../sessions/presentation/agent_status_badge.dart';
import 'package:karmashala_remote/companion.dart';

/// The desktop's status vocabulary for a session the host described — same
/// glyphs, words and semantic colours as [agentStatusAppearance].
AgentActivityStatus agentStatusOf(CompanionSessionStatus status) =>
    switch (status) {
      CompanionSessionStatus.working => AgentActivityStatus.working,
      CompanionSessionStatus.idle => AgentActivityStatus.idle,
      CompanionSessionStatus.needsYou => AgentActivityStatus.awaitingApproval,
      CompanionSessionStatus.failed => AgentActivityStatus.failed,
      CompanionSessionStatus.unknown => AgentActivityStatus.unknown,
    };

/// A status badge fed by the gateway rather than by desktop providers.
class CompanionStatusBadge extends StatelessWidget {
  const CompanionStatusBadge({
    required this.status,
    this.showLabel = false,
    super.key,
  });

  final CompanionSessionStatus status;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final appearance = agentStatusAppearance(agentStatusOf(status));
    final semantic = SemanticColors.of(context);
    final colour = appearance.colour(semantic);
    // `neutral` measures 3.9:1 as small text on a light card, so the word
    // borrows the text ramp; the glyph keeps it, since icons need only 3:1.
    final wordColour = colour == semantic.neutral
        ? theme.colorScheme.onSurfaceVariant
        : colour;
    return Semantics(
      label: 'Session status: ${appearance.label}',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            appearance.icon,
            // Chrome's pointer step, not UiDensity's 11: beside `labelSmall` an
            // 11px mark disappears.
            size: density.isTouch ? Touch.iconSmall : Chrome.iconSmall,
            color: colour,
          ),
          if (showLabel) ...[
            SizedBox(width: density.glyphGap),
            Text(
              appearance.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  (density.isTouch
                          ? theme.textTheme.bodySmall
                          : theme.textTheme.labelSmall)
                      ?.copyWith(
                        color: wordColour,
                        fontWeight: FontWeight.w600,
                      ),
            ),
          ],
        ],
      ),
    );
  }
}
