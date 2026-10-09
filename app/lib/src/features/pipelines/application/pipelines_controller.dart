import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_automations/pipelines.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../data/pipelines_data.dart';

/// The templates, the saved pipelines and the recent runs, as the server
/// last told them.
class PipelinesState {
  const PipelinesState({
    this.templates = const [],
    this.saved = const [],
    this.runs = const {},
    this.loaded = false,
    this.error,
  });

  final List<PipelineDefinition> templates;
  final List<PipelineDefinition> saved;
  final Map<String, PipelineRun> runs;
  final bool loaded;
  final String? error;

  /// Templates first, then the person's own.
  List<PipelineDefinition> get all => [...templates, ...saved];

  /// Newest first.
  List<PipelineRun> get runsNewestFirst =>
      runs.values.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  PipelinesState copyWith({
    List<PipelineDefinition>? templates,
    List<PipelineDefinition>? saved,
    Map<String, PipelineRun>? runs,
    bool? loaded,
    String? error,
    bool clearError = false,
  }) => PipelinesState(
    templates: templates ?? this.templates,
    saved: saved ?? this.saved,
    runs: runs ?? this.runs,
    loaded: loaded ?? this.loaded,
    error: clearError ? null : error ?? this.error,
  );
}

/// How long a finished run stays on the dashboard.
const Duration kPipelineFinishedShownFor = Duration(hours: 1);

/// Keeps [PipelinesState] from the server's list and its changes, and does
/// what a person asks of a run.
class PipelinesController extends Notifier<PipelinesState> {
  StreamSubscription<PipelinesChange>? _changes;

  PipelinesData get _data => ref.read(pipelinesDataProvider);

  @override
  PipelinesState build() {
    final data = ref.watch(pipelinesDataProvider);
    _changes = data.changes.listen(_apply);
    ref.onDispose(() => unawaited(_changes?.cancel()));
    Future.microtask(refresh);
    return const PipelinesState(templates: []);
  }

  Future<void> refresh() async {
    try {
      final snapshot = await _data.list();
      state = state.copyWith(
        templates: snapshot.templates,
        saved: snapshot.saved,
        runs: {...state.runs, for (final run in snapshot.runs) run.id: run},
        loaded: true,
        clearError: true,
      );
    } on Object catch (error) {
      state = state.copyWith(loaded: true, error: '$error');
    }
  }

  void _apply(PipelinesChange change) {
    switch (change) {
      case PipelineRunChanged(:final run):
        state = state.copyWith(runs: {...state.runs, run.id: run});
      case PipelineChanged(:final pipeline):
        state = state.copyWith(
          saved:
              [
                for (final p in state.saved)
                  if (p.id != pipeline.id) p,
                pipeline,
              ]..sort(
                (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
              ),
        );
      case PipelineRemoved(:final id):
        state = state.copyWith(
          saved: [
            for (final p in state.saved)
              if (p.id != id) p,
          ],
        );
    }
  }

  void _took(PipelineRun run) =>
      state = state.copyWith(runs: {...state.runs, run.id: run});

  Future<PipelineRun> start({
    required PipelineDefinition definition,
    required String repositoryId,
    required String input,
  }) async {
    final run = await _data.start(
      definition: definition,
      repositoryId: repositoryId,
      input: input,
    );
    _took(run);
    return run;
  }

  Future<void> approve(String runId, {String? handoff}) async =>
      _took(await _data.approve(runId, handoff: handoff));

  Future<void> stop(String runId) async => _took(await _data.stop(runId));

  Future<void> retry(String runId) async => _took(await _data.retry(runId));

  Future<void> skip(String runId) async => _took(await _data.skip(runId));

  Future<PipelineDefinition> save(PipelineDefinition pipeline) async {
    final saved = await _data.save(pipeline);
    _apply(PipelineChanged(saved));
    return saved;
  }

  Future<void> delete(String id) async {
    await _data.delete(id);
    _apply(PipelineRemoved(id));
  }
}

final pipelinesProvider = NotifierProvider<PipelinesController, PipelinesState>(
  PipelinesController.new,
);

/// The runs the dashboard shows: every one still running or waiting, and one
/// that ended — finished, failed or stopped — within the last hour. Older
/// ones are in the run list.
List<PipelineRun> dashboardPipelineRuns(
  PipelinesState state, {
  required DateTime now,
}) => [
  for (final run in state.runsNewestFirst)
    if (run.state.isActive ||
        now.difference(run.finishedAt ?? run.updatedAt) <
            kPipelineFinishedShownFor)
      run,
];
