import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_automations/pipelines.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/workbench_tabs.dart' show openWorkflowRuns;
import '../../../app/widgets/adaptive_modal.dart';
import '../../../core/util/clock_provider.dart';
import '../../explorer/application/agent_state_providers.dart';
import '../../explorer/application/agent_states.dart';
import '../../pipelines/application/pipelines_controller.dart';
import '../../pipelines/presentation/pipeline_run_card.dart';
import '../../workflows/application/workflows_state.dart' show WorkflowRunKind;
import '../../pipelines/presentation/pipeline_words.dart';
import '../application/overview_pipeline_peek.dart';
import '../application/overview_prefs.dart';
import '../application/overview_providers.dart';
import '../application/overview_reads.dart'
    show overviewGlanceProvider, overviewLastAnswerProvider;

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
          // Every run, both kinds, is in Workflows → Runs.
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: const ValueKey('overview-pipelines-more'),
              onPressed: () =>
                  openWorkflowRuns(ref, kind: WorkflowRunKind.pipeline),
              child: Text(switch (more) {
                0 => 'See all runs',
                1 => '1 more run…',
                _ => '$more more runs…',
              }),
            ),
          ),
        ],
      ),
    );
  }
}

/// One run, compact: its name and state, where it is (stage 2 of 3 · 12m ·
/// loop 1/2), its stages — a click shows a stage's session in the run's
/// peek — what it waits on, its current stage's last line, and the one
/// thing to do about it, worded as a button. A click opens the run's peek.
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
    final now = ref.watch(clockProvider).nowUtc();
    final waitingOn = pipelineRunWaitingOn(run, asking: asking);
    final current = run.current;
    final session = current?.sessionId;
    final working =
        run.state.isActive &&
        current != null &&
        !current.state.isSettled &&
        current.state != PipelineStageState.approval;
    final lastLine = pipelineStageLastLine(
      current,
      doing: session == null || !working
          ? null
          : ref
                .watch(overviewGlanceProvider(session))
                .asData
                ?.value
                ?.open
                .lastOrNull
                ?.phrase,
      lastAnswer: session == null || !working
          ? null
          : ref.watch(overviewLastAnswerProvider(session)).asData?.value.text,
    );
    final peeked = ref.watch(
      pipelinePeekProvider.select((p) => p?.runId == run.id),
    );
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    void open() => ref.read(pipelinePeekProvider.notifier).open(run.id);
    return Material(
      key: ValueKey('overview-pipeline:${run.id}'),
      color: peeked
          ? scheme.primary.withValues(alpha: StateLayers.selectedAlpha)
          : scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        side: BorderSide(color: edge),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('overview-pipeline-open:${run.id}'),
        onTap: open,
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
                    tooltip: 'Open the run',
                    visualDensity: UiDensity.of(context).controlDensity,
                    onPressed: open,
                    icon: const Icon(AppIcons.list),
                  ),
                ],
              ),
              Text(
                pipelineRunProgress(run, now: now),
                key: ValueKey('overview-pipeline-progress:${run.id}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: muted?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: Insets.xs),
              PipelineStageFlow(run: run),
              if (waitingOn != null)
                Padding(
                  padding: const EdgeInsets.only(top: Insets.xs),
                  child: Text(
                    waitingOn,
                    key: ValueKey(
                      asking != null
                          ? 'overview-pipeline-asking:${run.id}'
                          : 'overview-pipeline-waiting:${run.id}',
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: switch (run.state) {
                        _ when needsYou => semantic.attention,
                        PipelineRunState.failed => semantic.failure,
                        _ => scheme.onSurfaceVariant,
                      },
                    ),
                  ),
                ),
              if (lastLine != null)
                Padding(
                  padding: const EdgeInsets.only(top: Insets.xxs),
                  child: Text(
                    lastLine,
                    key: ValueKey('overview-pipeline-last-line:${run.id}'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: muted?.copyWith(fontStyle: FontStyle.italic),
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
                          onPressed: () =>
                              _act(context, controller.stop(run.id)),
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
                          onPressed: () =>
                              _act(context, controller.skip(run.id)),
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
