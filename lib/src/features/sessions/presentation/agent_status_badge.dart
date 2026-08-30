import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../agents/domain/agent_status.dart';
import '../application/session_status_providers.dart';

/// Icon, colour and words for one [AgentActivityStatus].
///
/// The words are not decoration. `unknown` is a real state — most agents sit
/// there until hooks are installed — and a badge that showed only a grey dot
/// would be indistinguishable from a badge that failed to load. Colour is never
/// the only carrier: every state has its own glyph and its own label.
({IconData icon, String label, Color Function(ColorScheme) colour})
agentStatusAppearance(AgentActivityStatus status) => switch (status) {
  AgentActivityStatus.working => (
    icon: AppIcons.circleHalf,
    label: 'Working',
    colour: (scheme) => scheme.primary,
  ),
  AgentActivityStatus.idle => (
    icon: AppIcons.checkCircle,
    label: 'Idle',
    colour: (scheme) => scheme.tertiary,
  ),
  AgentActivityStatus.awaitingApproval => (
    icon: AppIcons.warningCircle,
    label: 'Needs you',
    colour: (scheme) => scheme.error,
  ),
  AgentActivityStatus.failed => (
    icon: AppIcons.xCircle,
    label: 'Failed',
    colour: (scheme) => scheme.error,
  ),
  AgentActivityStatus.unknown => (
    icon: AppIcons.question,
    label: 'Unknown',
    colour: (scheme) => scheme.outline,
  ),
};

/// How a status was arrived at, for the tooltip. Saying *which* source answered
/// is what makes `unknown` actionable — "no source could tell" is a different
/// problem from "the transcript says idle".
String agentStatusExplanation(AgentStatusReport report) {
  final how = switch (report.source) {
    AgentStatusSource.hook => 'from an installed hook',
    AgentStatusSource.stateFile => "from the agent's transcript",
    AgentStatusSource.terminalGrid => "from the agent's terminal",
    AgentStatusSource.none => 'no source could tell',
  };
  final detail = report.detail;
  return detail == null || detail.isEmpty ? how : '$how ($detail)';
}

/// A small live status badge for one session.
///
/// Renders `unknown` rather than nothing while the first observation is in
/// flight, so the row's width does not jump when the answer arrives.
class AgentStatusBadge extends ConsumerWidget {
  const AgentStatusBadge({
    required this.sessionId,
    this.showLabel = false,
    super.key,
  });

  final String sessionId;

  /// Whether to draw the word beside the glyph. Off in a dense list, on where
  /// there is room for it.
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = ref
        .watch(agentSessionStatusProvider(sessionId))
        .asData
        ?.value;
    final status = report?.status ?? AgentActivityStatus.unknown;
    final appearance = agentStatusAppearance(status);
    final theme = Theme.of(context);
    final colour = appearance.colour(theme.colorScheme);

    return Tooltip(
      message: report == null
          ? '${appearance.label} — waiting for the first observation'
          : '${appearance.label} — ${agentStatusExplanation(report)}',
      child: Semantics(
        label: 'Agent status: ${appearance.label}',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(appearance.icon, size: 13, color: colour),
            if (showLabel) ...[
              const SizedBox(width: 4),
              Text(
                appearance.label,
                style: theme.textTheme.labelSmall?.copyWith(color: colour),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
