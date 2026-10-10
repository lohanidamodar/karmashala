import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_automations/pipelines.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/widgets/adaptive_modal.dart';
import '../../../core/util/clock_provider.dart';
import '../../explorer/application/agent_state_providers.dart';
import '../../explorer/application/agent_states.dart';
import '../../pipelines/application/pipelines_controller.dart';
import '../../pipelines/presentation/pipeline_run_card.dart';
import '../../pipelines/presentation/pipeline_run_detail.dart';
import '../../pipelines/presentation/pipeline_words.dart';
import '../application/overview_prefs.dart';
import '../application/overview_providers.dart';

/// [run] as the Board's state filters read it: a gate, or a stage asking
/// something, needs you; a failure has failed; a finished run is ready.
AgentState pipelineRunBoardState(
  PipelineRun run, {
  bool stageNeedsYou = false,
}) => switch (run.state) {
  _ when pipelineRunAtGate(run) || stageNeedsYou => AgentState.needsYou,
  PipelineRunState.running || PipelineRunState.waiting => AgentState.working,
  PipelineRunState.failed => AgentState.failed,
  PipelineRunState.finished => AgentState.ready,
  PipelineRunState.stopped => AgentState.ended,
};

/// The stage of [run] whose session waits on you, if one does.
PipelineStageRecord? pipelineStageAsking(
  PipelineRun run,
  bool Function(String sessionId) asks,
) {
  for (final record in run.records.reversed) {
    final id = record.sessionId;
    if (id != null && asks(id)) return record;
  }
  return null;
}

/// **The Pipelines lane**: each run the dashboard shows as one card, its
/// stages a compact flow with the current one marked and a gate's Approve
/// in reach. Its stages' sessions are drawn here and in no other lane.
/// Nothing while no run is shown, or the Board's filter leaves none.
class OverviewPipelineLane extends ConsumerWidget {
  const OverviewPipelineLane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).nowUtc();
    final runs = dashboardPipelineRuns(ref.watch(pipelinesProvider), now: now);
    if (runs.isEmpty) return const SizedBox.shrink();
    final filter = ref.watch(overviewPrefsProvider.select((p) => p.filter));
    final asking = ref.watch(needsYouProvider);
    final shown = [
      for (final run in runs)
        if (filter.shows(
          pipelineRunBoardState(
            run,
            stageNeedsYou: pipelineStageAsking(run, asking.containsKey) != null,
          ),
        ))
          run,
    ].take(kDashboardPipelineCards).toList();
    if (shown.isEmpty) return const SizedBox.shrink();
    final more = runs.length - shown.length;
    return Padding(
      key: const ValueKey('overview-pipeline-lane'),
      padding: const EdgeInsets.only(top: Insets.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          EyebrowLabel(
            'Pipelines · ${runs.length}',
            padding: const EdgeInsets.only(bottom: Insets.sm),
          ),
          for (final run in shown)
            Padding(
              padding: const EdgeInsets.only(bottom: Insets.sm),
              child: OverviewPipelineCard(
                run: run,
                asking: pipelineStageAsking(run, asking.containsKey),
              ),
            ),
          if (more > 0)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                key: const ValueKey('overview-pipelines-more'),
                onPressed: () => unawaited(showPipelineRuns(context)),
                child: Text(more == 1 ? '1 more run…' : '$more more runs…'),
              ),
            ),
        ],
      ),
    );
  }
}

/// One run, compact: its name and state, its stages — a click peeks a
/// stage's session — and the one thing it waits on, worded as a button.
class OverviewPipelineCard extends ConsumerWidget {
  const OverviewPipelineCard({required this.run, this.asking, super.key});

  final PipelineRun run;

  /// The stage whose session asks you something, if one does.
  final PipelineStageRecord? asking;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final controller = ref.read(pipelinesProvider.notifier);
    final gate = pipelineRunAtGate(run);
    final asking = this.asking;
    final needsYou = gate || asking != null;
    final edge = switch (run.state) {
      _ when needsYou => semantic.attention.withValues(
        alpha: SemanticColors.surfaceEdgeAlpha,
      ),
      PipelineRunState.failed => semantic.failure.withValues(
        alpha: SemanticColors.surfaceEdgeAlpha,
      ),
      _ => scheme.outlineVariant,
    };
    final stateColor = switch (run.state) {
      _ when needsYou => semantic.attention,
      PipelineRunState.failed => semantic.failure,
      _ => scheme.onSurfaceVariant,
    };
    final ended =
        run.state == PipelineRunState.failed ||
        run.state == PipelineRunState.stopped;
    return Material(
      key: ValueKey('overview-pipeline:${run.id}'),
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        side: BorderSide(color: edge),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(Insets.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  AppIcons.treeStructure,
                  size: UiDensity.of(context).icon,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: run.definition.name,
                          style: theme.textTheme.titleSmall,
                        ),
                        TextSpan(
                          text: ' · ${pipelineRunStateLabel(run)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: stateColor,
                          ),
                        ),
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  key: ValueKey('overview-pipeline-details:${run.id}'),
                  tooltip: 'Run details',
                  visualDensity: UiDensity.of(context).controlDensity,
                  onPressed: () =>
                      unawaited(showPipelineRunDetail(context, run.id)),
                  icon: const Icon(AppIcons.list),
                ),
              ],
            ),
            const SizedBox(height: Insets.xs),
            PipelineStageFlow(run: run),
            if (asking != null)
              Padding(
                padding: const EdgeInsets.only(top: Insets.xs),
                child: Text(
                  '${asking.role} asks you something — click it to answer',
                  key: ValueKey('overview-pipeline-asking:${run.id}'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: semantic.attention,
                  ),
                ),
              ),
            if (gate || run.state == PipelineRunState.running || ended)
              Padding(
                padding: const EdgeInsets.only(top: Insets.xs),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: Insets.xs,
                  runSpacing: Insets.xs,
                  children: [
                    if (gate || run.state == PipelineRunState.running)
                      TextButton(
                        key: ValueKey('overview-pipeline-stop:${run.id}'),
                        onPressed: () => _act(context, controller.stop(run.id)),
                        child: const Text('Stop'),
                      ),
                    if (gate) ...[
                      OutlinedButton(
                        key: ValueKey('overview-pipeline-edit:${run.id}'),
                        onPressed: () => unawaited(_editHandoff(context)),
                        child: const Text('Edit hand-off…'),
                      ),
                      FilledButton.icon(
                        key: ValueKey('overview-pipeline-approve:${run.id}'),
                        onPressed: () =>
                            _act(context, controller.approve(run.id)),
                        icon: const Icon(AppIcons.check),
                        label: const Text('Approve'),
                      ),
                    ],
                    if (ended) ...[
                      TextButton(
                        key: ValueKey('overview-pipeline-skip:${run.id}'),
                        onPressed: () => _act(context, controller.skip(run.id)),
                        child: const Text('Skip'),
                      ),
                      FilledButton.tonal(
                        key: ValueKey('overview-pipeline-retry:${run.id}'),
                        onPressed: () =>
                            _act(context, controller.retry(run.id)),
                        child: const Text('Retry stage'),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The run's full card, whose hand-off can be read and edited before
  /// approving.
  Future<void> _editHandoff(BuildContext context) => showAdaptiveModal<void>(
    context: context,
    title: run.definition.name,
    builder: (_) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
      child: Consumer(
        builder: (context, ref, _) {
          final live = ref.watch(pipelinesProvider).runs[run.id] ?? run;
          return PipelineRunCard(run: live);
        },
      ),
    ),
  );
}

/// Runs [work], saying in a snack bar why it was refused.
void _act(BuildContext context, Future<void> work) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  unawaited(
    work.catchError((Object error) {
      messenger?.showSnackBar(SnackBar(content: Text('$error')));
    }),
  );
}
