import 'package:flutter/material.dart';

import '../../../app/theme/design_tokens.dart';
import '../../agents/domain/agent_status.dart';
import '../../sessions/presentation/agent_status_badge.dart';
import '../client/companion_gateway.dart';

/// The desktop's status vocabulary for a session the host described.
///
/// Same glyphs, same words, same semantic colours as [agentStatusAppearance] —
/// the phone must not invent a second visual language for the same fact.
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
    final appearance = agentStatusAppearance(agentStatusOf(status));
    final colour = appearance.colour(SemanticColors.of(context));
    return Semantics(
      label: 'Session status: ${appearance.label}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(appearance.icon, size: 13, color: colour),
          if (showLabel) ...[
            const SizedBox(width: 4),
            Text(
              appearance.label,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: colour),
            ),
          ],
        ],
      ),
    );
  }
}
