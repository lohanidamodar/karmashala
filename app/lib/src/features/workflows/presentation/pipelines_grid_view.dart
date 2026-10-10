import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_automations/pipelines.dart';
import 'package:karmashala_ui/charts.dart' show formatShare;
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../automations/presentation/automations_list_view.dart'
    show AutomationGrid, WorkflowCard;
import '../../pipelines/application/pipelines_controller.dart';
import '../../pipelines/presentation/pipeline_editor.dart';
import '../../pipelines/presentation/pipeline_run_dialog.dart';
import '../../pipelines/presentation/pipeline_words.dart';
import '../../terminal/presentation/session_status.dart' show describeAge;
import '../application/workflow_runs.dart';
import '../application/workflows_state.dart';
import 'workflows_tab_view.dart' show ListWithDetail;

/// **Pipelines**: the built-in templates and the person's own, each a card
/// with its stages, its last run and how its recent runs went. The editor
/// opens in the page: beside the grid when there is room, instead of it when
/// there is not.
class PipelinesGridView extends ConsumerWidget {
  const PipelinesGridView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editing = ref.watch(pipelineEditingProvider);
    return ListWithDetail(
      main: const _Grid(),
      detail: editing == null
          ? null
          : Material(
              color: Theme.of(context).colorScheme.surface,
              child: PipelineEditor(
                key: ValueKey('pipeline-editor-${editing.generation}'),
                initial: editing.draft,
                onDone: (_) =>
                    ref.read(pipelineEditingProvider.notifier).close(),
              ),
            ),
    );
  }
}

class _Grid extends ConsumerWidget {
  const _Grid();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(pipelinesProvider);
    final templates = state.templates.isEmpty
        ? kPipelineTemplates
        : state.templates;
    final saved = state.saved;
    final stats = ref.watch(pipelineRunStatsProvider);
    Widget grid(List<PipelineDefinition> pipelines) => AutomationGrid(
      count: pipelines.length,
      cell: (i) => PipelineCard(
        key: ValueKey('pipeline-tile:${pipelines[i].id}'),
        pipeline: pipelines[i],
        stats: stats[pipelines[i].id] ?? const PipelineRunStats(),
      ),
    );
    return ListView(
      key: const ValueKey('pipelines-grid'),
      padding: const EdgeInsets.all(Insets.lg),
      children: [
        if (state.error case final error?)
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.md),
            child: PaneNoticeBar(
              icon: AppIcons.warningCircle,
              tone: NoticeTone.attention,
              message: 'Pipelines not read: $error',
            ),
          ),
        if (!state.loaded)
          const Padding(
            padding: EdgeInsets.only(bottom: Insets.md),
            child: Row(
              children: [
                InlineSpinner(semanticsLabel: 'Reading pipelines'),
                SizedBox(width: Insets.xs),
                Flexible(child: Text('Reading pipelines…')),
              ],
            ),
          ),
        EyebrowLabel(
          'Your pipelines · ${saved.length}',
          padding: const EdgeInsets.only(bottom: Insets.sm),
        ),
        if (saved.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.md),
            child: Wrap(
              spacing: Insets.sm,
              runSpacing: Insets.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'None yet. Start from a template, or make a new one.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                TextButton.icon(
                  key: const ValueKey('pipeline-new-inline'),
                  onPressed: () =>
                      ref.read(pipelineEditingProvider.notifier).open(),
                  icon: const Icon(AppIcons.plus),
                  label: const Text('New pipeline'),
                ),
              ],
            ),
          )
        else
          grid(saved),
        EyebrowLabel(
          'Built-in templates · ${templates.length}',
          padding: const EdgeInsets.only(bottom: Insets.sm),
        ),
        grid(templates),
      ],
    );
  }
}

enum _PipelineAction { run, edit, duplicate, delete }

/// One pipeline: its name, its stages as a flow of roles, its last run and
/// its success rate; Run, Edit, Duplicate and — for one of the person's own —
/// Delete. A tap edits it.
class PipelineCard extends ConsumerWidget {
  const PipelineCard({required this.pipeline, required this.stats, super.key});

  final PipelineDefinition pipeline;
  final PipelineRunStats stats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall;
    final muted = small?.copyWith(color: scheme.onSurfaceVariant);
    final now = ref.watch(clockProvider).nowUtc();
    final last = stats.last;
    final rate = stats.rate;
    void act(_PipelineAction action) => switch (action) {
      _PipelineAction.run => unawaited(
        showRunPipeline(context, pipelineId: pipeline.id),
      ),
      _PipelineAction.edit =>
        ref.read(pipelineEditingProvider.notifier).open(pipeline),
      _PipelineAction.duplicate =>
        ref.read(pipelineEditingProvider.notifier).duplicate(pipeline),
      _PipelineAction.delete => unawaited(_delete(context, ref)),
    };
    return WorkflowCard(
      onTap: () => act(_PipelineAction.edit),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                AppIcons.treeStructure,
                color: scheme.tertiary,
                size: Touch.icon,
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text(
                  pipeline.name,
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              RowMenuButton(
                key: ValueKey('pipeline-menu:${pipeline.id}'),
                tooltip: 'More for ${pipeline.name}',
                onSelected: (value) =>
                    act(_PipelineAction.values.byName(value)),
                itemBuilder: () => [
                  DesktopMenuItem(
                    value: _PipelineAction.run.name,
                    label: 'Run…',
                    icon: AppIcons.play,
                  ),
                  DesktopMenuItem(
                    value: _PipelineAction.edit.name,
                    label: pipeline.builtIn ? 'Edit a copy' : 'Edit',
                    icon: AppIcons.pencilSimple,
                  ),
                  DesktopMenuItem(
                    value: _PipelineAction.duplicate.name,
                    label: 'Duplicate',
                    icon: AppIcons.copy,
                  ),
                  if (!pipeline.builtIn) ...[
                    const DesktopMenuDivider(),
                    DesktopMenuItem(
                      value: _PipelineAction.delete.name,
                      label: 'Delete…',
                      icon: AppIcons.trash,
                      destructive: true,
                    ),
                  ],
                ],
              ),
            ],
          ),
          if (pipeline.description.isNotEmpty)
            Text(
              pipeline.description,
              style: muted,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          const SizedBox(height: Insets.sm),
          PipelineRoleFlow(pipeline: pipeline),
          const Spacer(),
          const SizedBox(height: Insets.sm),
          Text(
            last == null
                ? 'Never run'
                : '${pipelineRunStateLabel(last)} · '
                      '${describeAge(last.createdAt, now: now)}',
            key: ValueKey('pipeline-last:${pipeline.id}'),
            style: small?.copyWith(
              color: last == null
                  ? scheme.onSurfaceVariant
                  : _runColor(context, last.state),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            rate == null
                ? 'No finished runs yet'
                : '${formatShare(stats.finished, stats.ended)} finished · '
                      'last ${stats.ended} ended',
            key: ValueKey('pipeline-rate:${pipeline.id}'),
            style: muted,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: Insets.xs),
          Wrap(
            spacing: Insets.xs,
            runSpacing: Insets.xs,
            children: [
              FilledButton.tonalIcon(
                key: ValueKey('pipeline-run:${pipeline.id}'),
                onPressed: () => act(_PipelineAction.run),
                icon: const Icon(AppIcons.play),
                label: const Text('Run'),
              ),
              TextButton(
                key: ValueKey('pipeline-edit:${pipeline.id}'),
                onPressed: () => act(_PipelineAction.edit),
                child: Text(pipeline.builtIn ? 'Edit a copy' : 'Edit'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final sure = await showConfirmDialog(
      context,
      title: 'Delete "${pipeline.name}"?',
      message:
          'Its runs stay listed in Runs. A run under way carries on with the '
          'stages it started with.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!sure) return;
    try {
      await ref.read(pipelinesProvider.notifier).delete(pipeline.id);
      final editing = ref.read(pipelineEditingProvider);
      if (editing?.draft.id == pipeline.id) {
        ref.read(pipelineEditingProvider.notifier).close();
      }
    } on Object catch (error) {
      messenger?.showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}

Color _runColor(BuildContext context, PipelineRunState state) {
  final semantic = SemanticColors.of(context);
  return switch (state) {
    PipelineRunState.running => semantic.working,
    PipelineRunState.waiting => semantic.attention,
    PipelineRunState.finished => semantic.idle,
    PipelineRunState.failed => semantic.failure,
    PipelineRunState.stopped => semantic.neutral,
  };
}

/// [pipeline]'s stages as a compact flow: a chip per role, arrows between,
/// wrapping onto more lines rather than scrolling sideways.
class PipelineRoleFlow extends StatelessWidget {
  const PipelineRoleFlow({required this.pipeline, super.key});

  final PipelineDefinition pipeline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      label: 'Stages: ${pipeline.stages.map((s) => s.role).join(', then ')}',
      excludeSemantics: true,
      child: Wrap(
        key: ValueKey('pipeline-flow:${pipeline.id}'),
        spacing: Insets.xxs,
        runSpacing: Insets.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final (i, stage) in pipeline.stages.indexed) ...[
            if (i > 0)
              Icon(
                AppIcons.caretRight,
                size: Chrome.iconSmall,
                color: scheme.outline,
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(Radii.pill),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Insets.sm,
                  vertical: Insets.xxs,
                ),
                child: Text(
                  stage.role,
                  style: theme.textTheme.labelSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
