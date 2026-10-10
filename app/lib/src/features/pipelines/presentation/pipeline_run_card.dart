import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_automations/pipelines.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_installations_controller.dart';
import '../../agents/application/agent_providers.dart';
import '../../overview/application/overview_providers.dart';
import '../application/pipelines_controller.dart';
import 'pipeline_run_detail.dart';
import 'pipeline_words.dart';

/// The most runs the dashboard draws as cards; the rest are in the run list.
const int kDashboardPipelineCards = 3;

/// **The dashboard's pipelines**: a card per run still going or just ended,
/// above the board. Nothing at all when there is none.
class OverviewPipelines extends ConsumerWidget {
  const OverviewPipelines({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).nowUtc();
    final runs = dashboardPipelineRuns(ref.watch(pipelinesProvider), now: now);
    if (runs.isEmpty) return const SizedBox.shrink();
    final shown = runs.take(kDashboardPipelineCards).toList();
    return ConstrainedBox(
      key: const ValueKey('overview-pipelines'),
      // The board below keeps most of the height, however many runs wait.
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.45,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Insets.md, Insets.sm, Insets.md, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final run in shown) ...[
              PipelineRunCard(run: run),
              const SizedBox(height: Insets.sm),
            ],
            if (runs.length > shown.length)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  key: const ValueKey('overview-pipelines-more'),
                  onPressed: () => unawaited(showPipelineRuns(context)),
                  child: Text('${runs.length - shown.length} more runs…'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One pipeline run: its stages as a flow, the current one marked, and what
/// the person can do about it — approve or edit the hand-off at a gate,
/// stop it, or retry or skip a stage that failed.
class PipelineRunCard extends ConsumerWidget {
  const PipelineRunCard({required this.run, super.key});

  final PipelineRun run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final radius = BorderRadius.circular(Radii.lg);
    final edge = switch (run.state) {
      PipelineRunState.waiting => semantic.attention.withValues(
        alpha: SemanticColors.surfaceEdgeAlpha,
      ),
      PipelineRunState.failed => semantic.failure.withValues(
        alpha: SemanticColors.surfaceEdgeAlpha,
      ),
      _ => scheme.outlineVariant,
    };
    final controller = ref.read(pipelinesProvider.notifier);
    final current = run.current;
    final waiting =
        run.state == PipelineRunState.waiting &&
        current?.state == PipelineStageState.approval;
    final ended =
        run.state == PipelineRunState.failed ||
        run.state == PipelineRunState.stopped;
    return Material(
      key: ValueKey('pipeline-card:${run.id}'),
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: edge),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(Insets.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  AppIcons.treeStructure,
                  size: Chrome.icon,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Text(
                    run.definition.name,
                    style: theme.textTheme.titleSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  key: ValueKey('pipeline-details:${run.id}'),
                  tooltip: 'Run details',
                  visualDensity: UiDensity.of(context).controlDensity,
                  onPressed: () =>
                      unawaited(showPipelineRunDetail(context, run.id)),
                  icon: const Icon(AppIcons.list),
                ),
              ],
            ),
            Text(
              pipelineRunStateLabel(run),
              key: ValueKey('pipeline-state:${run.id}'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: switch (run.state) {
                  PipelineRunState.waiting => semantic.attention,
                  PipelineRunState.failed => semantic.failure,
                  _ => scheme.onSurfaceVariant,
                },
              ),
            ),
            Text(
              run.input,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Insets.sm),
            PipelineStageFlow(run: run),
            if (waiting)
              _HandoffPanel(
                key: ValueKey('pipeline-handoff:${run.id}:${current!.attempt}'),
                run: run,
                record: current,
              ),
            if (ended && run.reason != null) ...[
              const SizedBox(height: Insets.sm),
              Text(
                run.reason!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: run.state == PipelineRunState.failed
                      ? semantic.failure
                      : scheme.onSurfaceVariant,
                ),
              ),
            ],
            if (run.state == PipelineRunState.running || ended)
              Padding(
                padding: const EdgeInsets.only(top: Insets.xs),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: Insets.xs,
                  children: [
                    if (run.state == PipelineRunState.running)
                      TextButton.icon(
                        key: ValueKey('pipeline-stop:${run.id}'),
                        onPressed: () => _act(context, controller.stop(run.id)),
                        icon: const Icon(AppIcons.stop),
                        label: const Text('Stop'),
                      ),
                    if (ended) ...[
                      TextButton.icon(
                        key: ValueKey('pipeline-skip:${run.id}'),
                        onPressed: () => _act(context, controller.skip(run.id)),
                        icon: const Icon(AppIcons.arrowBendDownRight),
                        label: const Text('Skip'),
                      ),
                      FilledButton.tonalIcon(
                        key: ValueKey('pipeline-retry:${run.id}'),
                        onPressed: () =>
                            _act(context, controller.retry(run.id)),
                        icon: const Icon(AppIcons.arrowCounterClockwise),
                        label: const Text('Retry stage'),
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

/// The stages of [run] in order: across on a wide card, down on a phone.
class PipelineStageFlow extends ConsumerWidget {
  const PipelineStageFlow({required this.run, super.key});

  final PipelineRun run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registry = ref.watch(agentRegistryProvider);
    final installations = ref.watch(agentInstallationsControllerProvider);
    String agentOf(PipelineStage stage) {
      final id = stage.agentInstallationId;
      if (id == null) return 'Default agent';
      final installation = installations.where((i) => i.id == id).firstOrNull;
      return installation == null
          ? 'Agent not installed'
          : registry.displayNameFor(installation.agentId);
    }

    final currentIndex = run.state.isActive ? run.current?.stageIndex : null;
    final pills = [
      for (var i = 0; i < run.definition.stages.length; i++)
        _StagePill(
          key: ValueKey('pipeline-stage:${run.id}:$i'),
          stage: run.definition.stages[i],
          record: run.latestOf(i),
          agent: agentOf(run.definition.stages[i]),
          current: i == currentIndex,
          onOpen: run.latestOf(i)?.sessionId == null
              ? null
              : () => ref
                    .read(overviewFocusProvider.notifier)
                    .peek(run.latestOf(i)!.sessionId!),
        ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final arrow = Icon(
          AppIcons.caretRight,
          size: Chrome.iconSmall,
          color: Theme.of(context).colorScheme.outline,
        );
        if (constraints.maxWidth < WidthClass.mediumMin) {
          return Column(
            key: ValueKey('pipeline-flow-vertical:${run.id}'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, pill) in pills.indexed) ...[
                if (i > 0) const SizedBox(height: Insets.xs),
                pill,
              ],
            ],
          );
        }
        return SingleChildScrollView(
          key: ValueKey('pipeline-flow-horizontal:${run.id}'),
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final (i, pill) in pills.indexed) ...[
                if (i > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
                    child: arrow,
                  ),
                pill,
              ],
            ],
          ),
        );
      },
    );
  }
}

class _StagePill extends StatelessWidget {
  const _StagePill({
    required this.stage,
    required this.record,
    required this.agent,
    required this.current,
    required this.onOpen,
    super.key,
  });

  final PipelineStage stage;
  final PipelineStageRecord? record;
  final String agent;
  final bool current;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = record?.state;
    final color = pipelineStageColor(context, state);
    final attempt = (record?.attempt ?? 1) > 1
        ? ' · try ${record!.attempt}'
        : '';
    final radius = BorderRadius.circular(Radii.md);
    return Tooltip(
      message:
          '${stage.role}: ${pipelineStageStateLabel(state)}'
          '${onOpen == null ? '' : ' — open its session'}',
      child: Material(
        color: current ? scheme.secondaryContainer : scheme.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: current ? scheme.primary : scheme.outlineVariant,
            width: current ? StateLayers.focusRingWidth : 1,
          ),
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.sm,
              vertical: Insets.xs,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(pipelineStageIcon(state), size: Chrome.icon, color: color),
                const SizedBox(width: Insets.xs),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${stage.role}$attempt',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium,
                      ),
                      Text(
                        '$agent · ${pipelineDuration(record?.duration)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The hand-off at an approval gate: read it, edit it, approve or stop.
class _HandoffPanel extends ConsumerStatefulWidget {
  const _HandoffPanel({required this.run, required this.record, super.key});

  final PipelineRun run;
  final PipelineStageRecord record;

  @override
  ConsumerState<_HandoffPanel> createState() => _HandoffPanelState();
}

class _HandoffPanelState extends ConsumerState<_HandoffPanel> {
  late final _text = TextEditingController(text: widget.record.handedOn);
  var _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _do(Future<void> Function() work) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await work();
    } on Object catch (error) {
      messenger?.showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final run = widget.run;
    final record = widget.record;
    final next = record.stageIndex + 1 < run.definition.stages.length
        ? run.definition.stages[record.stageIndex + 1].role
        : null;
    final controller = ref.read(pipelinesProvider.notifier);
    return Padding(
      padding: const EdgeInsets.only(top: Insets.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            next == null
                ? 'Approve what ${record.role} handed back to finish the run.'
                : 'Read and edit what ${record.role} hands to $next.',
            style: theme.textTheme.bodySmall,
          ),
          if (record.artifacts.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              child: Text(
                'Artifacts: ${record.artifacts.map((a) => a.title).join(', ')}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: Insets.xs),
          TextField(
            key: ValueKey('pipeline-handoff-text:${run.id}'),
            controller: _text,
            minLines: 3,
            maxLines: 8,
            style: theme.textTheme.bodySmall,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              labelText: 'Hand-off',
            ),
          ),
          const SizedBox(height: Insets.xs),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: Insets.xs,
            children: [
              TextButton.icon(
                key: ValueKey('pipeline-stop:${run.id}'),
                onPressed: _busy
                    ? null
                    : () => _do(() => controller.stop(run.id)),
                icon: const Icon(AppIcons.stop),
                label: const Text('Stop'),
              ),
              FilledButton.icon(
                key: ValueKey('pipeline-approve:${run.id}'),
                onPressed: _busy
                    ? null
                    : () => _do(
                        () => controller.approve(
                          run.id,
                          handoff: _text.text.trim() == record.handedOn.trim()
                              ? null
                              : _text.text,
                        ),
                      ),
                icon: const Icon(AppIcons.check),
                label: const Text('Approve'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
