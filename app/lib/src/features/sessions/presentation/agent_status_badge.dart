import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/tokens.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_ui/rows.dart';
import '../application/session_status_providers.dart';

/// How a status was arrived at, for the tooltip. Naming the source is what
/// makes `unknown` actionable — "nobody could tell" is not "the store says idle".
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

/// A small live status badge for one session. Renders `unknown` rather than
/// nothing while the first observation is in flight, so the width holds.
class AgentStatusBadge extends ConsumerWidget {
  const AgentStatusBadge({
    required this.sessionId,
    this.showLabel = false,
    this.size = Chrome.iconSmall,
    this.askShield = false,
    super.key,
  });

  /// The glyph's size; a row's status column asks for its own.
  final double size;

  final String sessionId;

  /// Whether to draw the word beside the glyph. Off in a dense list, on where
  /// there is room for it.
  final bool showLabel;

  /// Draws a session waiting on the user with the needs-you mark — the
  /// breathing shield, or the question mark for a question — where the row
  /// it heads takes the attention tone (spec §5).
  final bool askShield;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = ref
        .watch(agentSessionStatusProvider(sessionId))
        .asData
        ?.value;
    final status = report?.status ?? AgentActivityStatus.unknown;
    final appearance = agentStatusAppearance(status);
    final theme = Theme.of(context);
    final colour = appearance.colour(SemanticColors.of(context));

    return Tooltip(
      message: report == null
          ? '${appearance.label} — waiting for the first observation'
          : '${appearance.label} — ${agentStatusExplanation(report)}',
      child: Semantics(
        label: 'Agent status: ${appearance.label}',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (askShield && status == AgentActivityStatus.awaitingApproval)
              NeedsYouGlyph(
                size: size,
                question: report?.waiting == AgentWaitKind.question,
              )
            else
              StatusGlyph(status: status, size: size, color: colour),
            if (showLabel) ...[
              const SizedBox(width: Insets.xs),
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
