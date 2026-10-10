import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart' show compactAge;
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/workbench_tabs.dart' show openWorkflowsTab;
import '../../../app/widgets/dashboard_glance.dart';
import '../../../core/util/clock_provider.dart';
import '../application/workflow_runs.dart';
import '../application/workflows_state.dart';
import 'workflow_runs_view.dart' show workflowStatusColor;

/// **The Workflows glance**: today's runs, those waiting on you, today's
/// failures, and the newest run. A tap opens Workflows on its runs.
const workflowsGlance = DashboardGlance(
  id: 'workflows',
  title: 'Workflows',
  icon: AppIcons.flowArrow,
  build: _body,
  onOpen: _open,
);

Widget _body(BuildContext context) => const WorkflowsGlanceBody();

void _open(BuildContext context, WidgetRef ref) =>
    openWorkflowsTab(ref, section: WorkflowsSection.runs);

/// The glance's body alone: the dashboard draws the tile around it. One line
/// on a phone's strip ([GlanceScope.compactOf]).
class WorkflowsGlanceBody extends ConsumerWidget {
  const WorkflowsGlanceBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final facts = ref.watch(workflowsGlanceProvider);
    final now = ref.watch(clockProvider).nowUtc();
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final counts = [
      facts.today == 1 ? '1 run today' : '${facts.today} runs today',
      if (facts.waiting > 0) '${facts.waiting} waiting on you',
      if (facts.failed > 0) '${facts.failed} failed',
    ].join(' · ');
    final line = Row(
      children: [
        Icon(
          facts.waiting > 0
              ? AppIcons.warningCircle
              : facts.failed > 0
              ? AppIcons.xCircle
              : AppIcons.checkCircle,
          size: Chrome.iconAction,
          color: facts.waiting > 0
              ? semantic.attention
              : facts.failed > 0
              ? semantic.failure
              : semantic.idle,
        ),
        const SizedBox(width: Insets.xs),
        Expanded(
          child: Text(
            counts,
            key: const ValueKey('workflows-glance-counts'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
    if (GlanceScope.compactOf(context)) return line;
    final newest = facts.newest;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        line,
        const SizedBox(height: Insets.xs),
        if (newest == null)
          Text(
            'Nothing has run yet.',
            key: const ValueKey('workflows-glance-empty'),
            style: muted,
          )
        else
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: '${newest.name} · '),
                TextSpan(
                  text: newest.statusWords ?? newest.status.label,
                  style: TextStyle(
                    color: workflowStatusColor(context, newest.status),
                  ),
                ),
                TextSpan(
                  text: ' · ${compactAge(now.difference(newest.startedAt))}',
                ),
              ],
            ),
            key: const ValueKey('workflows-glance-newest'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: muted,
          ),
      ],
    );
  }
}
