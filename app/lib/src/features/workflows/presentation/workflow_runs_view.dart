import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/charts.dart' show formatMoney;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/phone_shell.dart' show phoneWorkbenchOpener;
import '../../../app/widgets/adaptive_modal.dart';
import '../../../app/widgets/fact_list.dart' show FactRow;
import '../../../core/util/clock_provider.dart';
import '../../automations/application/automation_providers.dart';
import '../../explorer/application/explorer_actions.dart';
import '../../automations/application/automation_runs_page.dart';
import '../../automations/presentation/automation_runs_view.dart' show RunTile;
import '../../overview/presentation/overview_filters.dart'
    show OverviewChecklist;
import '../../pipelines/application/pipelines_controller.dart';
import '../../pipelines/presentation/pipeline_run_card.dart';
import '../../pipelines/presentation/pipeline_run_detail.dart';
import '../../pipelines/presentation/pipeline_words.dart' show pipelineDuration;
import '../../terminal/presentation/session_status.dart' show describeAge;
import '../application/workflow_runs.dart';
import '../application/workflows_state.dart';
import 'workflows_tab_view.dart' show ListWithDetail;

/// The glyph of a run's kind.
IconData workflowKindIcon(WorkflowRunKind kind) => switch (kind) {
  WorkflowRunKind.automation => AppIcons.lightning,
  WorkflowRunKind.pipeline => AppIcons.treeStructure,
};

Color workflowStatusColor(BuildContext context, WorkflowRunStatus status) {
  final semantic = SemanticColors.of(context);
  return switch (status) {
    WorkflowRunStatus.running => semantic.working,
    WorkflowRunStatus.waitingOnYou => semantic.attention,
    WorkflowRunStatus.done => semantic.idle,
    WorkflowRunStatus.failed => semantic.failure,
    WorkflowRunStatus.stopped => semantic.neutral,
  };
}

/// A run's status as a small coloured label; the word carries it, never the
/// colour alone.
class WorkflowStatusChip extends StatelessWidget {
  const WorkflowStatusChip({required this.row, super.key});

  final WorkflowRunRow row;

  @override
  Widget build(BuildContext context) {
    final color = workflowStatusColor(context, row.status);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: StateLayers.selectedAlpha),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.sm,
          vertical: Insets.xxs,
        ),
        child: Text(
          row.statusWords ?? row.status.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
        ),
      ),
    );
  }
}

/// **Runs**: every automation run and pipeline run, newest first, narrowed by
/// state, kind and project. A run opens its detail beside the list, or over
/// it on a narrow page.
class WorkflowRunsView extends ConsumerWidget {
  const WorkflowRunsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedWorkflowRunProvider);
    return ListWithDetail(
      main: const _RunList(),
      detail: selected == null
          ? null
          : WorkflowRunDetailPane(key: ValueKey('$selected'), run: selected),
    );
  }
}

class _RunList extends ConsumerWidget {
  const _RunList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(shownWorkflowRunRowsProvider);
    final all = ref.watch(workflowRunRowsProvider);
    final only = ref.watch(runsFilterProvider.select((f) => f.automationId));
    final automation = only == null
        ? null
        : ref.watch(automationsDataProvider).getById(only);
    final filters = ref.watch(workflowRunsFilterProvider);
    final selected = ref.watch(selectedWorkflowRunProvider);
    final chips = [
      if (only != null)
        InputChip(
          key: const ValueKey('runs-automation-chip'),
          label: Text(automation?.name ?? 'One automation'),
          onDeleted: () => ref.read(runsFilterProvider.notifier).only(null),
        ),
      if (filters.count > 0)
        ActionChip(
          key: const ValueKey('workflow-runs-clear'),
          avatar: const Icon(AppIcons.x, size: Chrome.iconSmall),
          label: Text(
            filters.count == 1 ? '1 filter set' : '${filters.count} filters',
          ),
          onPressed: ref.read(workflowRunsFilterProvider.notifier).clear,
        ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = WidthClass.of(
          constraints.maxWidth,
          textScaler: MediaQuery.textScalerOf(context),
        ).isExpanded;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (chips.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Insets.lg,
                  Insets.sm,
                  Insets.lg,
                  0,
                ),
                child: Wrap(
                  spacing: Insets.sm,
                  runSpacing: Insets.xs,
                  children: chips,
                ),
              ),
            Expanded(
              child: rows.isEmpty
                  ? PanePlaceholder(
                      icon: AppIcons.flowArrow,
                      message: all.isEmpty
                          ? 'Nothing has run yet. Automations and pipelines '
                                'list their runs here.'
                          : 'No runs match.',
                    )
                  : ListView.builder(
                      key: const ValueKey('workflow-runs-list'),
                      padding: const EdgeInsets.only(bottom: Insets.lg),
                      itemCount: rows.length + (columns ? 2 : 1),
                      itemBuilder: (context, index) {
                        if (columns && index == 0) return const _Header();
                        final i = columns ? index - 1 : index;
                        if (i == rows.length) return const _OlderButton();
                        final row = rows[i];
                        return WorkflowRunTile(
                          key: ValueKey('workflow-run:${row.ref}'),
                          row: row,
                          columns: columns,
                          selected: row.ref == selected,
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

const _statusWidth = Touch.target * 3;
const _byWidth = Touch.target * 2.5;
const _whenWidth = Touch.target * 1.75;
const _tookWidth = Touch.target * 1.5;
const _costWidth = Touch.target * 1.5;
const _projectWidth = Touch.target * 2.5;

class _Cell extends StatelessWidget {
  const _Cell({required this.width, required this.child});

  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: MediaQuery.textScalerOf(context).scale(width),
    child: Padding(
      padding: const EdgeInsetsDirectional.only(end: Insets.sm),
      child: DefaultTextStyle.merge(
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        child: child,
      ),
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.fromLTRB(
      Insets.lg + Touch.icon + Insets.sm,
      Insets.sm,
      Insets.lg,
      Insets.xs,
    ),
    child: Row(
      children: [
        Expanded(child: EyebrowLabel('Run')),
        SizedBox(width: Insets.sm),
        _Cell(width: _statusWidth, child: EyebrowLabel('Status')),
        _Cell(width: _byWidth, child: EyebrowLabel('Started by')),
        _Cell(width: _whenWidth, child: EyebrowLabel('When')),
        _Cell(width: _tookWidth, child: EyebrowLabel('Took')),
        _Cell(width: _costWidth, child: EyebrowLabel('Cost')),
        _Cell(width: _projectWidth, child: EyebrowLabel('Project')),
      ],
    ),
  );
}

/// The name a checkout goes by in Runs.
String _projectOf(WidgetRef ref, String repositoryId) =>
    ref
        .watch(automationCheckoutsProvider)
        .where((r) => r.id == repositoryId)
        .firstOrNull
        ?.name ??
    'A checkout that is gone';

/// One run in Runs: its kind, name, status, stage, who started it, when, how
/// long, its cost and its project — in columns on a wide page, on two lines
/// on a narrow one. A tap opens its detail.
class WorkflowRunTile extends ConsumerWidget {
  const WorkflowRunTile({
    required this.row,
    required this.columns,
    this.selected = false,
    super.key,
  });

  final WorkflowRunRow row;
  final bool columns;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final now = ref.watch(clockProvider).nowUtc();
    final cost = ref.watch(workflowRunCostProvider(row.costKey));
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final age = describeAge(row.startedAt, now: now);
    final took = pipelineDuration(row.durationAt(now));
    final project = _projectOf(ref, row.repositoryId);
    final money = cost == null ? null : formatMoney(cost.amount, cost.currency);
    final name = Text(
      row.name,
      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    final stage = row.stage == null
        ? null
        : Text(
            row.stage!,
            key: ValueKey('workflow-run-stage:${row.ref}'),
            style: quiet,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: StateLayers.selectedAlpha)
          : Colors.transparent,
      child: InkWell(
        onTap: () =>
            ref.read(selectedWorkflowRunProvider.notifier).select(row.ref),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.lg,
            vertical: Insets.sm,
          ),
          child: Row(
            children: [
              Tooltip(
                message: row.kind.label,
                child: Icon(
                  workflowKindIcon(row.kind),
                  size: Touch.icon,
                  color: scheme.tertiary,
                ),
              ),
              const SizedBox(width: Insets.sm),
              if (columns) ...[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [name, ?stage],
                  ),
                ),
                const SizedBox(width: Insets.sm),
                _Cell(
                  width: _statusWidth,
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: WorkflowStatusChip(row: row),
                  ),
                ),
                _Cell(
                  width: _byWidth,
                  child: Text(row.startedBy, style: quiet),
                ),
                _Cell(
                  width: _whenWidth,
                  child: Text(age, style: quiet),
                ),
                _Cell(
                  width: _tookWidth,
                  child: Text(took, style: quiet),
                ),
                _Cell(
                  width: _costWidth,
                  child: Text(money ?? '—', style: quiet),
                ),
                _Cell(
                  width: _projectWidth,
                  child: Text(project, style: quiet),
                ),
              ] else ...[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      name,
                      Text(
                        [
                          ?row.stage,
                          row.startedBy,
                          age,
                          took,
                          ?money,
                          project,
                        ].join(' · '),
                        key: ValueKey('workflow-run-meta:${row.ref}'),
                        style: quiet,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Insets.sm),
                Flexible(child: WorkflowStatusChip(row: row)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Older automation runs than the app holds, a page at a time.
class _OlderButton extends ConsumerWidget {
  const _OlderButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(olderRunsProvider);
    final bool more = page.more ?? ref.watch(runsCopyTruncatedProvider);
    if (!more) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.all(Insets.md),
      child: Center(
        child: page.loading
            ? const InlineSpinner(semanticsLabel: 'Reading older runs')
            : TextButton(
                key: const ValueKey('runs-older'),
                onPressed: () =>
                    ref.read(olderRunsProvider.notifier).loadMore(),
                child: const Text('Show older automation runs'),
              ),
      ),
    );
  }
}

/// The filter control for Runs: state, kind and project, as checklists.
class WorkflowRunsFilterButton extends ConsumerWidget {
  const WorkflowRunsFilterButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Builder(
    builder: (context) => FilterFunnelButton(
      key: const ValueKey('workflow-runs-filter'),
      count: ref.watch(workflowRunsFilterProvider.select((f) => f.count)),
      onPressed: () => showAdaptivePopover<void>(
        context: context,
        title: 'Filter runs',
        builder: (_) => const WorkflowRunsFilterPanel(),
      ),
    ),
  );
}

/// State, kind and project: a checklist each, with counts, applied as they
/// are ticked.
class WorkflowRunsFilterPanel extends ConsumerWidget {
  const WorkflowRunsFilterPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(workflowRunsFilterProvider);
    final controller = ref.read(workflowRunsFilterProvider.notifier);
    final rows = ref.watch(workflowRunRowsProvider);
    int count(bool Function(WorkflowRunRow row) test) =>
        rows.where(test).length;
    final repositories = ref.watch(automationCheckoutsProvider);
    final projectIds = {for (final row in rows) row.repositoryId}.toList()
      ..sort();
    String projectName(String id) =>
        repositories.where((r) => r.id == id).firstOrNull?.name ??
        'A checkout that is gone';
    return SingleChildScrollView(
      key: const ValueKey('workflow-runs-filter-panel'),
      padding: const EdgeInsets.only(bottom: Insets.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OverviewChecklist(
            keyPrefix: 'runs-state',
            title: 'State',
            noun: 'states',
            options: [
              for (final status in WorkflowRunStatus.values)
                (
                  id: status.name,
                  label: status.label,
                  count: count((r) => r.status == status),
                ),
            ],
            selected: filter.statuses?.map((s) => s.name).toSet(),
            onChanged: (ids) => controller.setStatuses(
              ids?.map(WorkflowRunStatus.values.byName).toSet(),
            ),
          ),
          OverviewChecklist(
            keyPrefix: 'runs-kind',
            title: 'Kind',
            noun: 'kinds',
            options: [
              for (final kind in WorkflowRunKind.values)
                (
                  id: kind.name,
                  label: kind.label,
                  count: count((r) => r.kind == kind),
                ),
            ],
            selected: filter.kinds?.map((k) => k.name).toSet(),
            onChanged: (ids) => controller.setKinds(
              ids?.map(WorkflowRunKind.values.byName).toSet(),
            ),
          ),
          OverviewChecklist(
            keyPrefix: 'runs-project',
            title: 'Project',
            noun: 'projects',
            options: [
              for (final id in projectIds)
                (
                  id: id,
                  label: projectName(id),
                  count: count((r) => r.repositoryId == id),
                ),
            ],
            selected: filter.projects,
            onChanged: controller.setProjects,
          ),
        ],
      ),
    );
  }
}

/// **A run's detail**: the automation run's steps and what can be done about
/// it, or the pipeline run's card and stages — with who started it, its
/// project and its cost over them.
class WorkflowRunDetailPane extends ConsumerWidget {
  const WorkflowRunDetailPane({required this.run, super.key});

  final WorkflowRunRef run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final row = ref
        .watch(workflowRunRowsProvider)
        .where((r) => r.ref == run)
        .firstOrNull;
    void close() => ref.read(selectedWorkflowRunProvider.notifier).select(null);
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.xs,
        Insets.xs,
        Insets.sm,
        Insets.xs,
      ),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('workflow-run-detail-close'),
            tooltip: 'Back to the runs',
            icon: const Icon(AppIcons.arrowLeft),
            onPressed: close,
          ),
          const SizedBox(width: Insets.xxs),
          Expanded(
            flex: 3,
            child: Text(
              row?.name ?? 'Run',
              style: theme.textTheme.titleMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (row != null) ...[
            const SizedBox(width: Insets.sm),
            Flexible(
              flex: 2,
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: WorkflowStatusChip(row: row),
              ),
            ),
          ],
        ],
      ),
    );
    final Widget body;
    if (row == null) {
      body = const PanePlaceholder(
        icon: AppIcons.flowArrow,
        message: 'This run is no longer listed.',
      );
    } else if (run.kind == WorkflowRunKind.automation) {
      final data = ref.watch(automationsDataProvider);
      final older = ref.watch(olderRunsProvider);
      final automationRun =
          data.runRows.where((r) => r.id == run.id).firstOrNull ??
          older.runs.where((r) => r.id == run.id).firstOrNull;
      body = automationRun == null
          ? const SizedBox.shrink()
          : ListView(
              key: ValueKey('workflow-run-detail:$run'),
              children: [
                _Facts(row: row),
                RunTile(
                  run: automationRun,
                  checks: ref.watch(
                    automationRunChecksProvider(automationRun.id),
                  ),
                  initiallyOpen: true,
                ),
              ],
            );
    } else {
      final pipelineRun = ref.watch(
        pipelinesProvider.select((s) => s.runs[run.id]),
      );
      body = pipelineRun == null
          ? const SizedBox.shrink()
          : PipelineRunDetail(
              key: ValueKey('workflow-run-detail:$run'),
              runId: run.id,
              header: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Facts(row: row, padded: false),
                  PipelineRunCard(
                    run: pipelineRun,
                    showDetails: false,
                    onOpenStage: (id) => openStageSession(context, ref, id),
                  ),
                ],
              ),
            );
    }
    return Column(
      key: const ValueKey('workflow-run-detail'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        const Divider(height: 1),
        Expanded(child: body),
      ],
    );
  }
}

/// Opens stage session [id] in its tab — the run's own detail, off the
/// dashboard, has no peek to show it in.
Future<void> openStageSession(
  BuildContext context,
  WidgetRef ref,
  String id,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final showWorkbench = phoneWorkbenchOpener(context, ref);
  final result = await ref.read(explorerActionsProvider).openNative(id);
  if (!result.isFailure) showWorkbench?.call();
  if (result.message case final message?) {
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Who started a run, in which project, when, for how long and at what cost.
class _Facts extends ConsumerWidget {
  const _Facts({required this.row, this.padded = true});

  final WorkflowRunRow row;
  final bool padded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).nowUtc();
    final cost = ref.watch(workflowRunCostProvider(row.costKey));
    final facts = [
      (workflowKindIcon(row.kind), 'Kind', row.kind.label),
      (AppIcons.userCircle, 'Started by', row.startedBy),
      (AppIcons.folder, 'Project', _projectOf(ref, row.repositoryId)),
      (AppIcons.clock, 'Started', describeAge(row.startedAt, now: now)),
      (
        AppIcons.clockCounterClockwise,
        'Took',
        pipelineDuration(row.durationAt(now)),
      ),
      (
        AppIcons.chartBar,
        'Cost',
        cost == null ? 'not recorded' : formatMoney(cost.amount, cost.currency),
      ),
    ];
    final style = Theme.of(context).textTheme.bodySmall;
    return Padding(
      key: ValueKey('workflow-run-facts:${row.ref}'),
      padding: padded
          ? const EdgeInsets.only(top: Insets.xs)
          : const EdgeInsets.only(bottom: Insets.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (icon, label, value) in facts)
            FactRow(
              icon: icon,
              label: label,
              value: Text(value, style: style),
            ),
        ],
      ),
    );
  }
}
