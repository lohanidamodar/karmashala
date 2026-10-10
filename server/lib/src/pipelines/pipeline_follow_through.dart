import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/pipelines.dart';
import 'package:karmashala_automations/runner.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/watched.dart';

import 'server_pipelines.dart';

/// The automations' "Run a pipeline" step over the server's pipelines: the
/// run is attributed to the automation run, and, started by nobody at the
/// screen, its stages launch as background work.
class ServerStepPipelines implements StepPipelineStarter {
  /// Set once the pipelines are built, after the automations.
  ServerPipelines? pipelines;

  @override
  Future<StepPipelineStarted> start(
    Automation automation,
    AutomationRun run, {
    required String pipelineId,
    required String repositoryId,
    required String input,
  }) async {
    final pipelines =
        this.pipelines ?? (throw StateError('This server runs no pipelines.'));
    final definition =
        pipelines.definitionNamed(pipelineId) ??
        (throw StateError(
          'The pipeline it names is gone. Pick another in the step.',
        ));
    try {
      final started = pipelines.startRun(
        definition: definition,
        repositoryId: repositoryId,
        input: input,
        automation: PipelineRunAutomation(
          automationId: automation.id,
          runId: run.id,
          name: automation.name,
        ),
      );
      return StepPipelineStarted(runId: started.id, name: definition.name);
    } on ArgumentError catch (error) {
      throw StateError('${error.message}');
    }
  }
}

/// **A pipeline run's gates and failures in the inbox**: filed when a run
/// this server watched moves to one, taken off when it moves on. A run first
/// seen already held — a restart picking it up — files nothing again.
class PipelineInbox {
  PipelineInbox({
    required this.raise,
    required this.retire,
    required this.projectName,
    required this.now,
  });

  final void Function(InboxItem item) raise;

  /// Takes item [id] off the inbox, when it is still there.
  final void Function(String id) retire;
  final String Function(String repositoryId) projectName;
  final DateTime Function() now;

  final _states = <String, PipelineRunState>{};
  final _filed = <String, String>{};

  void moved(PipelineRun run) {
    final before = _states[run.id];
    _states[run.id] = run.state;
    if (before == run.state) return;
    if (_filed.remove(run.id) case final id?) retire(id);
    if (before == null) return;
    final item = pipelineInboxItem(
      run,
      project: projectName(run.repositoryId),
      at: now(),
    );
    if (item == null) return;
    _filed[run.id] = item.id;
    raise(item);
  }
}

/// [run]'s inbox item, for a run held at a gate or failed: opening it opens
/// the run. Null in every other state.
InboxItem? pipelineInboxItem(
  PipelineRun run, {
  required String project,
  required DateTime at,
}) {
  final kind = switch (run.state) {
    PipelineRunState.waiting => InboxItemKind.pipelineWaiting,
    PipelineRunState.failed => InboxItemKind.pipelineFailed,
    _ => null,
  };
  if (kind == null) return null;
  final stage = run.current?.role;
  final openId = pipelineInboxOpenId(run.id);
  final detail = kind == InboxItemKind.pipelineWaiting
      ? 'Waiting for your approval at ${stage ?? 'a gate'} · $project'
      : 'Failed at ${stage ?? 'the start'} · $project'
            '${run.reason == null ? '' : ': ${run.reason}'}';
  final attempt = '${run.id}@${run.records.length}';
  return InboxItem(
    session: WatchedSession(
      key: AgentSessionKey('pipelines', attempt),
      label: run.definition.name,
      openId: openId,
      imported: false,
    ),
    kind: kind,
    at: at,
    detail: detail,
    id: '$openId@${run.records.length}:${kind.name}',
  );
}
