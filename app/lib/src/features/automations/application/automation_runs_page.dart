import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_automations/records.dart'
    show compareRunsNewestFirst, kRunsCopiedPerAutomation;
import 'package:karmashala_automations/checks.dart';
import 'package:karmashala_automations/runs.dart';

import 'automation_providers.dart';

/// Which runs the Runs tab shows.
enum RunsShown { all, failed, running }

class RunsFilter {
  const RunsFilter({this.shown = RunsShown.all, this.automationId});

  final RunsShown shown;

  /// One automation's runs only, or null for every automation's.
  final String? automationId;
}

class RunsFilterNotifier extends Notifier<RunsFilter> {
  @override
  RunsFilter build() => const RunsFilter();

  void show(RunsShown shown) =>
      state = RunsFilter(shown: shown, automationId: state.automationId);

  void only(String? automationId) =>
      state = RunsFilter(shown: state.shown, automationId: automationId);
}

final runsFilterProvider = NotifierProvider<RunsFilterNotifier, RunsFilter>(
  RunsFilterNotifier.new,
);

/// Runs older than the client's copy, fetched a page at a time.
class OlderRuns {
  const OlderRuns({
    this.runs = const [],
    this.checks = const {},
    this.more,
    this.loading = false,
  });

  final List<AutomationRun> runs;
  final Map<String, List<AutomationCheckVerdict>> checks;

  /// Whether the server keeps runs older than every one shown; null until
  /// a page was asked for.
  final bool? more;
  final bool loading;
}

class OlderRunsNotifier extends Notifier<OlderRuns> {
  @override
  OlderRuns build() {
    // Another automation is another list: what was paged for one is not the
    // next one's.
    ref.watch(runsFilterProvider.select((f) => f.automationId));
    return const OlderRuns();
  }

  Future<void> loadMore() async {
    if (state.loading || state.more == false) return;
    // The oldest run shown, read here: the shown list depends on this.
    final only = ref.read(runsFilterProvider).automationId;
    DateTime? before;
    for (final run in [...state.runs, ...ref.read(allAutomationRunsProvider)]) {
      if (only != null && run.automationId != only) continue;
      if (before == null || run.firedAt.isBefore(before)) before = run.firedAt;
    }
    state = OlderRuns(runs: state.runs, checks: state.checks, loading: true);
    try {
      final page = await ref
          .read(automationsDataProvider)
          .runsPage(
            before: before,
            automationId: ref.read(runsFilterProvider).automationId,
          );
      state = OlderRuns(
        runs: [...state.runs, ...page.runs],
        checks: {...state.checks, ...page.checks},
        more: page.more,
      );
    } on Object {
      state = OlderRuns(runs: state.runs, checks: state.checks, more: false);
      rethrow;
    }
  }
}

final olderRunsProvider = NotifierProvider<OlderRunsNotifier, OlderRuns>(
  OlderRunsNotifier.new,
);

/// The copy's runs and every older page fetched, once each, newest first —
/// of the filtered automation only when one is picked.
final shownRunsProvider = Provider<List<AutomationRun>>((ref) {
  final only = ref.watch(runsFilterProvider.select((f) => f.automationId));
  final byId = <String, AutomationRun>{
    for (final run in ref.watch(olderRunsProvider).runs) run.id: run,
    for (final run in ref.watch(allAutomationRunsProvider)) run.id: run,
  };
  return [
    for (final run in byId.values)
      if (only == null || run.automationId == only) run,
  ]..sort(compareRunsNewestFirst);
});

/// Whether the copy may be missing older runs: it keeps a fixed number per
/// automation, so one that reached it may have more at the server.
final runsCopyTruncatedProvider = Provider<bool>((ref) {
  final only = ref.watch(runsFilterProvider.select((f) => f.automationId));
  final counts = <String, int>{};
  for (final run in ref.watch(allAutomationRunsProvider)) {
    counts[run.automationId] = (counts[run.automationId] ?? 0) + 1;
  }
  return counts.entries.any(
    (e) =>
        (only == null || e.key == only) && e.value >= kRunsCopiedPerAutomation,
  );
});
