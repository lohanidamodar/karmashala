import 'package:flutter/material.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_ui/rows.dart';

/// The desktop's status vocabulary for a session the host described — same
/// glyphs, words and semantic colours as [agentStatusAppearance]. Null for an
/// ending ([CompanionSessionStatus.isEnding]), which is not an agent status.
AgentActivityStatus? agentStatusOf(CompanionSessionStatus status) =>
    switch (status) {
      CompanionSessionStatus.working => AgentActivityStatus.working,
      CompanionSessionStatus.idle => AgentActivityStatus.idle,
      CompanionSessionStatus.needsYou => AgentActivityStatus.awaitingApproval,
      CompanionSessionStatus.failed => AgentActivityStatus.failed,
      CompanionSessionStatus.unknown => AgentActivityStatus.unknown,
      CompanionSessionStatus.ended ||
      CompanionSessionStatus.stoppedByYou => null,
    };

/// Icon, colour and words for [status]: the agent's, or how the session
/// ended. Words always; colour never the only carrier.
({IconData icon, String label, Color Function(SemanticColors) colour})
companionStatusAppearance(CompanionSessionStatus status) => switch (status) {
  CompanionSessionStatus.ended => (
    icon: AppIcons.check,
    label: 'Ended',
    colour: (semantic) => semantic.neutral,
  ),
  CompanionSessionStatus.stoppedByYou => (
    icon: AppIcons.stopCircle,
    label: 'Stopped by you',
    colour: (semantic) => semantic.neutral,
  ),
  _ => agentStatusAppearance(agentStatusOf(status)!),
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
    final appearance = companionStatusAppearance(status);
    final semantic = SemanticColors.of(context);
    final colour = appearance.colour(semantic);
    // `neutral` measures 3.9:1 as small text on a light card, so the word
    // borrows the text ramp; the glyph keeps it, since icons need only 3:1.
    final wordColour = colour == semantic.neutral
        ? theme.colorScheme.onSurfaceVariant
        : colour;
    // Chrome's pointer step, not UiDensity's 11: beside `labelSmall` an 11px
    // mark disappears.
    final glyphSize = density.isTouch ? Touch.iconSmall : Chrome.iconSmall;
    final agent = agentStatusOf(status);
    return Semantics(
      label: 'Session status: ${appearance.label}',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (agent != null)
            StatusGlyph(status: agent, size: glyphSize, color: colour)
          else
            Icon(appearance.icon, size: glyphSize, color: colour),
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
