import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/checks.dart';
import 'package:karmashala_automations/pipelines.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_core/verdicts.dart';

import '../../../core/util/clock_provider.dart';
import '../../automations/application/automation_providers.dart';
import '../../automations/application/automation_runs_page.dart';
import '../../pipelines/application/pipelines_controller.dart';
import '../../sessions/application/session_usage_providers.dart';
import 'workflows_state.dart';

/// Where a run in Runs is, in five words for both kinds.
enum WorkflowRunStatus {
  running('Running'),
  waitingOnYou('Waiting on you'),
  done('Done'),
  failed('Failed'),
  stopped('Stopped');

  const WorkflowRunStatus(this.label);

  final String label;

  bool get isActive => this == running || this == waitingOnYou;
}

/// Who started a run in Runs.
enum WorkflowStarter {
  person('You'),
  automation('Automation'),
  agent('An agent'),
  unknown('Not recorded');

  const WorkflowStarter(this.label);

  final String label;
}

/// **One run in Runs**, an automation's or a pipeline's, as its row says it.
@immutable
class WorkflowRunRow {
  const WorkflowRunRow({
    required this.ref,
    required this.name,
    required this.status,
    required this.startedBy,
    required this.starter,
    required this.startedAt,
    required this.repositoryId,
    required this.ownerId,
    this.finishedAt,
    this.stage,
    this.sessionIds = const [],
    this.statusWords,
  });

  final WorkflowRunRef ref;
  final String name;
  final WorkflowRunStatus status;

  /// "You", the automation's name, "An agent", or how an automation fired.
  final String startedBy;
  final WorkflowStarter starter;
  final DateTime startedAt;
  final DateTime? finishedAt;

  /// A pipeline's stage now, by its role.
  final String? stage;
  final String repositoryId;

  /// The automation, or the pipeline as its run snapshot names it.
  final String ownerId;

  /// The sessions it ran, whose reported spend is its cost.
  final List<String> sessionIds;

  /// Its own words where they say more than [status]: "Waiting on pipeline".
  final String? statusWords;

  WorkflowRunKind get kind => ref.kind;

  /// Its sessions, as [workflowRunCostProvider] is asked for them.
  String get costKey => sessionIds.join('|');

  /// How long it took, or has taken so far by [now].
  Duration durationAt(DateTime now) =>
      (finishedAt ?? now).difference(startedAt);
}

/// [run] as a row: [checks] decide whether a finished one failed, and a run
/// whose pipeline step still runs is running.
WorkflowRunRow automationRunRow(
  AutomationRun run, {
  required Automation? automation,
  required List<AutomationCheckVerdict> checks,
}) {
  final waitsOnPipeline = run.stepResults.any(
    (s) => s.outcome == AutomationStepOutcome.waiting,
  );
  final failedAfter =
      checks.any((c) => c.verdict != VerificationVerdict.pass) ||
      run.stepResults.any((s) => s.outcome == AutomationStepOutcome.failed);
  final status = switch (run.state) {
    AutomationRunState.queued ||
    AutomationRunState.running => WorkflowRunStatus.running,
    AutomationRunState.failed ||
    AutomationRunState.missed => WorkflowRunStatus.failed,
    AutomationRunState.unrecognised => WorkflowRunStatus.stopped,
    AutomationRunState.finished when failedAfter => WorkflowRunStatus.failed,
    AutomationRunState.finished when waitsOnPipeline =>
      WorkflowRunStatus.running,
    AutomationRunState.finished => WorkflowRunStatus.done,
  };
  final cause = run.startedBy;
  return WorkflowRunRow(
    ref: WorkflowRunRef(WorkflowRunKind.automation, run.id),
    name: automation?.name ?? 'An automation that is gone',
    status: status,
    startedBy: cause == AutomationRunCause.runNow
        ? WorkflowStarter.person.label
        : (cause?.label ??
              (automation?.isWebhook ?? false
                  ? AutomationRunCause.webhook.label
                  : run.eventSessionId != null
                  ? AutomationRunCause.event.label
                  : AutomationRunCause.schedule.label)),
    starter: cause == AutomationRunCause.runNow
        ? WorkflowStarter.person
        : WorkflowStarter.automation,
    startedAt: run.firedAt,
    finishedAt: run.state.isLive ? null : run.finishedAt,
    repositoryId: automation?.repositoryId ?? '',
    ownerId: run.automationId,
    sessionIds: [?run.sessionId],
    statusWords: status == WorkflowRunStatus.running && waitsOnPipeline
        ? 'Waiting on pipeline'
        : null,
  );
}

/// Whether [run] holds at a gate, or a stage asks something of a person.
bool pipelineRunWaitsOnYou(PipelineRun run) =>
    run.state == PipelineRunState.waiting;

/// [run] as a row.
WorkflowRunRow pipelineRunRow(PipelineRun run) {
  final starter = switch (run.startedBy) {
    PipelineRunStarter.person => WorkflowStarter.person,
    PipelineRunStarter.automation => WorkflowStarter.automation,
    PipelineRunStarter.agent => WorkflowStarter.agent,
    PipelineRunStarter.unknown => WorkflowStarter.unknown,
  };
  return WorkflowRunRow(
    ref: WorkflowRunRef(WorkflowRunKind.pipeline, run.id),
    name: run.definition.name,
    status: switch (run.state) {
      PipelineRunState.running => WorkflowRunStatus.running,
      PipelineRunState.waiting => WorkflowRunStatus.waitingOnYou,
      PipelineRunState.finished => WorkflowRunStatus.done,
      PipelineRunState.failed => WorkflowRunStatus.failed,
      PipelineRunState.stopped => WorkflowRunStatus.stopped,
    },
    startedBy: run.automation?.name ?? starter.label,
    starter: starter,
    startedAt: run.createdAt,
    finishedAt: run.state.isActive ? null : (run.finishedAt ?? run.updatedAt),
    stage: run.current?.role,
    repositoryId: run.repositoryId,
    ownerId: run.definition.id,
    sessionIds: [for (final record in run.records) ?record.sessionId],
  );
}

/// What Runs narrows to: null in each is every choice.
@immutable
class WorkflowRunsFilter {
  const WorkflowRunsFilter({this.statuses, this.kinds, this.projects});

  final Set<WorkflowRunStatus>? statuses;
  final Set<WorkflowRunKind>? kinds;
  final Set<String>? projects;

  /// How many of the three are set.
  int get count => [statuses, kinds, projects].where((s) => s != null).length;

  bool shows(WorkflowRunRow row) =>
      (statuses?.contains(row.status) ?? true) &&
      (kinds?.contains(row.kind) ?? true) &&
      (projects?.contains(row.repositoryId) ?? true);

  WorkflowRunsFilter copyWith({
    Set<WorkflowRunStatus>? Function()? statuses,
    Set<WorkflowRunKind>? Function()? kinds,
    Set<String>? Function()? projects,
  }) => WorkflowRunsFilter(
    statuses: statuses == null ? this.statuses : statuses(),
    kinds: kinds == null ? this.kinds : kinds(),
    projects: projects == null ? this.projects : projects(),
  );
}

class WorkflowRunsFilterNotifier extends Notifier<WorkflowRunsFilter> {
  @override
  WorkflowRunsFilter build() => const WorkflowRunsFilter();

  void setStatuses(Set<WorkflowRunStatus>? statuses) =>
      state = state.copyWith(statuses: () => statuses);

  void setKinds(Set<WorkflowRunKind>? kinds) =>
      state = state.copyWith(kinds: () => kinds);

  void setProjects(Set<String>? projects) =>
      state = state.copyWith(projects: () => projects);

  void clear() => state = const WorkflowRunsFilter();
}

final workflowRunsFilterProvider =
    NotifierProvider<WorkflowRunsFilterNotifier, WorkflowRunsFilter>(
      WorkflowRunsFilterNotifier.new,
    );

/// Every run the app holds, both kinds, newest first: the copy's automation
/// runs, the older ones paged in past it, and the pipeline runs.
final workflowRunRowsProvider = Provider<List<WorkflowRunRow>>((ref) {
  final data = ref.watch(automationsDataProvider);
  final held = ref.watch(allAutomationRunsProvider);
  final older = ref.watch(olderRunsProvider);
  final pipelines = ref.watch(pipelinesProvider);
  final heldIds = {for (final run in held) run.id};
  return [
    for (final run in held)
      automationRunRow(
        run,
        automation: data.getById(run.automationId),
        checks: data.checksFor(run.id),
      ),
    for (final run in older.runs)
      if (!heldIds.contains(run.id))
        automationRunRow(
          run,
          automation: data.getById(run.automationId),
          checks: older.checks[run.id] ?? const [],
        ),
    for (final run in pipelines.runs.values) pipelineRunRow(run),
  ]..sort((a, b) => b.startedAt.compareTo(a.startedAt));
});

/// The rows [workflowRunsFilterProvider] leaves — only one automation's, when
/// its card asked for its runs ([RunsFilter.automationId]).
final shownWorkflowRunRowsProvider = Provider<List<WorkflowRunRow>>((ref) {
  final filter = ref.watch(workflowRunsFilterProvider);
  final only = ref.watch(runsFilterProvider.select((f) => f.automationId));
  return [
    for (final row in ref.watch(workflowRunRowsProvider))
      if (filter.shows(row) &&
          (only == null ||
              (row.kind == WorkflowRunKind.automation && row.ownerId == only)))
        row,
  ];
});

/// How many recent runs a pipeline card's success rate reads.
const int kPipelineRateRuns = 20;

/// A pipeline's last run and how its recent ones went.
@immutable
class PipelineRunStats {
  const PipelineRunStats({this.last, this.ended = 0, this.finished = 0});

  final PipelineRun? last;

  /// Of the last [kPipelineRateRuns], how many ended and how many of them
  /// finished. A rate of ended runs: one still running is neither.
  final int ended;
  final int finished;

  /// Null while none has ended: no rate, not 0%.
  double? get rate => ended == 0 ? null : finished / ended;
}

/// Each pipeline's [PipelineRunStats], by its id. A run is a pipeline's when
/// its snapshot has the pipeline's id.
final pipelineRunStatsProvider = Provider<Map<String, PipelineRunStats>>((ref) {
  final runs = ref.watch(pipelinesProvider).runsNewestFirst;
  final byId = <String, List<PipelineRun>>{};
  for (final run in runs) {
    (byId[run.definition.id] ??= []).add(run);
  }
  return {
    for (final MapEntry(:key, :value) in byId.entries)
      key: () {
        final recent = value.take(kPipelineRateRuns);
        final ended = recent.where((r) => !r.state.isActive);
        return PipelineRunStats(
          last: value.first,
          ended: ended.length,
          finished: ended.where((r) => r.state.isOver).length,
        );
      }(),
  };
});

/// The Workflows glance's facts: today's runs, those waiting on you, those
/// that failed, and the newest.
@immutable
class WorkflowsGlanceFacts {
  const WorkflowsGlanceFacts({
    required this.today,
    required this.waiting,
    required this.failed,
    this.newest,
  });

  final int today;
  final int waiting;
  final int failed;
  final WorkflowRunRow? newest;
}

/// [rows] counted for the glance, "today" being since local midnight of
/// [now], and failures those of today.
WorkflowsGlanceFacts workflowsGlanceFacts(
  List<WorkflowRunRow> rows, {
  required DateTime now,
}) {
  final local = now.toLocal();
  final midnight = DateTime(local.year, local.month, local.day);
  final today = [
    for (final row in rows)
      if (!row.startedAt.toLocal().isBefore(midnight)) row,
  ];
  return WorkflowsGlanceFacts(
    today: today.length,
    waiting: rows
        .where((r) => r.status == WorkflowRunStatus.waitingOnYou)
        .length,
    failed: today.where((r) => r.status == WorkflowRunStatus.failed).length,
    newest: rows.firstOrNull,
  );
}

final workflowsGlanceProvider = Provider<WorkflowsGlanceFacts>(
  (ref) => workflowsGlanceFacts(
    ref.watch(workflowRunRowsProvider),
    now: ref.watch(clockProvider).nowUtc(),
  ),
);

/// What the sessions in [WorkflowRunRow.costKey] reported spending, summed:
/// null when none reported any, or they spent in different currencies —
/// "not recorded", never 0.
final workflowRunCostProvider = Provider.autoDispose
    .family<({double amount, String? currency})?, String>((ref, sessions) {
      double? total;
      String? currency;
      for (final id in sessions.split('|')) {
        if (id.isEmpty) continue;
        final usage = ref.watch(sessionUsageProvider(id));
        final amount = usage?.costAmount;
        if (amount == null) continue;
        if (total != null && usage!.costCurrency != currency) return null;
        currency = usage!.costCurrency;
        total = (total ?? 0) + amount;
      }
      return total == null ? null : (amount: total, currency: currency);
    });
