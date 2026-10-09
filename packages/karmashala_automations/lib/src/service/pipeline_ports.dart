import '../domain/pipeline.dart';
import '../domain/pipeline_run.dart';

/// Whose wait a stage launch is: a person's run goes ahead of background work.
enum StagePriority { person, background }

/// One stage session to start.
class StageLaunch {
  const StageLaunch({
    required this.runId,
    required this.repositoryId,
    required this.title,
    required this.prompt,
    required this.workspace,
    required this.priority,
    this.systemPrompt,
    this.installationId,
    this.modelId,
    this.permissionMode,
    this.worktreePath,
    this.environmentId,
    this.parentSessionId,
  });

  final String runId;
  final String repositoryId;
  final String title;
  final String prompt;
  final String? systemPrompt;
  final PipelineWorkspace workspace;
  final StagePriority priority;
  final String? installationId;
  final String? modelId;
  final String? permissionMode;

  /// With [PipelineWorkspace.previousWorktree]: the worktree to join.
  final String? worktreePath;
  final String? environmentId;

  /// The session that started the run, whose sub-session this stage is.
  final String? parentSessionId;
}

/// A started stage session and where it works.
class StageLaunched {
  const StageLaunched({
    required this.sessionId,
    this.worktreePath,
    this.environmentId,
    this.branch,
  });

  final String sessionId;
  final String? worktreePath;
  final String? environmentId;
  final String? branch;
}

/// Starts a stage's session. The server's goes through the launch gate, so a
/// run never starts more agents than the machine allows.
abstract interface class StageLauncher {
  Future<StageLaunched> launch(StageLaunch launch);
}

/// How a stage session's turn ended.
class StageTurn {
  const StageTurn.done(String this.answer) : failure = null;
  const StageTurn.failed(String this.failure) : answer = null;

  final String? answer;
  final String? failure;
}

/// Follows stage sessions.
abstract interface class StageWatcher {
  /// Completes once [sessionId]'s turn begun at [since] is over, however
  /// long that takes.
  Future<StageTurn> turnOf(String sessionId, {required DateTime since});

  /// Ends [sessionId]'s agent.
  Future<void> stop(String sessionId);
}

/// What a stage left behind, read for its hand-off and its gate.
abstract interface class StageEvidence {
  Future<List<PipelineArtifactRef>> artifactsOf(String sessionId);

  /// The text of artifact [artifactId], or null when it cannot be read.
  Future<String?> artifactText(String artifactId);

  /// Runs [command] — or, when blank, the checkout's project checks — in the
  /// stage's workspace, recorded as one verification run with its identity.
  Future<PipelineCheckRecord> check({
    required String sessionId,
    required String repositoryId,
    required String command,
    String? worktreePath,
    String? environmentId,
  });
}

/// Saved pipelines and their runs.
abstract interface class PipelineRecords {
  List<PipelineDefinition> definitions();
  PipelineDefinition? definition(String id);
  void saveDefinition(PipelineDefinition definition, DateTime at);
  void deleteDefinition(String id);

  PipelineRun? run(String id);

  /// Newest first.
  List<PipelineRun> runs({int limit = 50});

  /// Runs still running or waiting, oldest first.
  List<PipelineRun> active();
  void putRun(PipelineRun run);
}
