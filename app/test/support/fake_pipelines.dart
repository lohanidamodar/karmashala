part of 'fake_data_server.dart';

/// The server's pipelines in a [FakeDataServer]: saved definitions and runs
/// a test seeds with [putRun], and every act a client asked of a run.
class FakePipelineRows {
  FakePipelineRows._(this._server);

  final FakeDataServer _server;
  final saved = <String, PipelineDefinition>{};
  final runs = <String, PipelineRun>{};

  /// `approve r1 <handoff>`, `stop r1`, `start <input>` — in order.
  final acts = <String>[];
  var _ids = 0;

  /// [run] as the server would tell it moving.
  void putRun(PipelineRun run) {
    runs[run.id] = run;
    _server._tell(null, [PipelineRunChanged(run)]);
  }

  PipelineRun _run(String id) =>
      runs[id] ?? (throw DataRefused.notFound('no pipeline run $id'));

  PipelineRun _changed(PipelineRun run, List<DataChange> changes) {
    runs[run.id] = run;
    changes.add(PipelineRunChanged(run));
    return run;
  }

  Object? _handle(PipelinesRequest<Object?> request, List<DataChange> changes) {
    switch (request) {
      case PipelinesList():
        return PipelinesSnapshot(
          templates: kPipelineTemplates,
          saved: saved.values.toList(),
          runs: runs.values.toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt)),
        );
      case PipelineSave(:final pipeline):
        final refusal = pipelineDefinitionRefusal(pipeline);
        if (refusal != null) throw DataRefused.invalid(refusal);
        final stored = pipeline.copyWith(
          id: pipeline.id.isEmpty ? 'pipeline-${++_ids}' : pipeline.id,
          builtIn: false,
        );
        saved[stored.id] = stored;
        changes.add(PipelineChanged(stored));
        return stored;
      case PipelineDelete(:final id):
        saved.remove(id);
        changes.add(PipelineRemoved(id));
        return const DataAck();
      case PipelineRunStart(
        :final definition,
        :final repositoryId,
        :final input,
      ):
        acts.add('start $input');
        final now = _server._now();
        return _changed(
          PipelineRun(
            id: 'run-${++_ids}',
            definition: definition,
            repositoryId: repositoryId,
            input: input,
            state: PipelineRunState.running,
            byPerson: true,
            createdAt: now,
            updatedAt: now,
          ),
          changes,
        );
      case PipelineRunApprove(:final runId, :final handoff):
        acts.add('approve $runId${handoff == null ? '' : ' $handoff'}');
        final run = _run(runId);
        final current = run.current;
        return _changed(
          (current == null
                  ? run
                  : run.withCurrent(
                      current.copyWith(
                        state: PipelineStageState.done,
                        handoff: handoff,
                      ),
                    ))
              .copyWith(state: PipelineRunState.running),
          changes,
        );
      case PipelineRunStop(:final runId):
        acts.add('stop $runId');
        return _changed(
          _run(runId).copyWith(state: PipelineRunState.stopped),
          changes,
        );
      case PipelineRunRetry(:final runId):
        acts.add('retry $runId');
        return _changed(
          _run(runId).copyWith(state: PipelineRunState.running),
          changes,
        );
      case PipelineRunSkip(:final runId):
        acts.add('skip $runId');
        return _changed(
          _run(runId).copyWith(state: PipelineRunState.running),
          changes,
        );
    }
  }
}
