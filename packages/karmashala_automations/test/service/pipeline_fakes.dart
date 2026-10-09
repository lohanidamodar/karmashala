import 'dart:async';

import 'package:karmashala_automations/pipelines.dart';
import 'package:karmashala_core/verdicts.dart';

/// Pipelines and runs held in memory.
class MemoryPipelineRecords implements PipelineRecords {
  final defs = <String, PipelineDefinition>{};
  final stored = <String, PipelineRun>{};

  @override
  List<PipelineRun> active() =>
      stored.values.where((r) => r.state.isActive).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  @override
  PipelineDefinition? definition(String id) => defs[id];

  @override
  List<PipelineDefinition> definitions() => defs.values.toList();

  @override
  void deleteDefinition(String id) => defs.remove(id);

  @override
  void putRun(PipelineRun run) => stored[run.id] = run;

  @override
  PipelineRun? run(String id) => stored[id];

  @override
  List<PipelineRun> runs({int limit = 50}) =>
      (stored.values.toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt)))
          .take(limit)
          .toList();

  @override
  void saveDefinition(PipelineDefinition definition, DateTime at) =>
      defs[definition.id] = definition;
}

/// Stands in for the launch gate: records every launch and its priority.
class FakeStageLauncher implements StageLauncher {
  final launches = <StageLaunch>[];
  var _next = 0;

  /// A launch for this role throws.
  String? failRole;

  @override
  Future<StageLaunched> launch(StageLaunch launch) async {
    if (failRole != null && launch.title.startsWith(failRole!)) {
      throw StateError('no agent');
    }
    launches.add(launch);
    final id = 's${++_next}';
    final worktree = switch (launch.workspace) {
      PipelineWorkspace.newWorktree => '/wt/$id',
      PipelineWorkspace.previousWorktree => launch.worktreePath,
      PipelineWorkspace.source => null,
    };
    return StageLaunched(
      sessionId: id,
      worktreePath: worktree,
      environmentId: worktree == null ? null : 'local',
      branch: launch.workspace == PipelineWorkspace.newWorktree
          ? 'branch-$id'
          : null,
    );
  }
}

/// Fake agents: each session's turn ends when the test says.
class FakeStageWatcher implements StageWatcher {
  final turns = <String, Completer<StageTurn>>{};
  final stopped = <String>[];

  Completer<StageTurn> _turn(String id) => turns[id] ??= Completer();

  void answer(String sessionId, String text) =>
      _turn(sessionId).complete(StageTurn.done(text));

  void fail(String sessionId, String why) =>
      _turn(sessionId).complete(StageTurn.failed(why));

  @override
  Future<StageTurn> turnOf(String sessionId, {required DateTime since}) =>
      _turn(sessionId).future;

  @override
  Future<void> stop(String sessionId) async {
    stopped.add(sessionId);
    final turn = _turn(sessionId);
    if (!turn.isCompleted) turn.complete(const StageTurn.failed('stopped'));
  }
}

class FakeStageEvidence implements StageEvidence {
  final artifacts = <String, List<PipelineArtifactRef>>{};
  final texts = <String, String>{};

  /// Each check's verdict, in turn; pass once they run out.
  final verdicts = <VerificationVerdict>[];
  final checks = <String>[];

  @override
  Future<List<PipelineArtifactRef>> artifactsOf(String sessionId) async =>
      artifacts[sessionId] ?? const [];

  @override
  Future<String?> artifactText(String artifactId) async => texts[artifactId];

  @override
  Future<PipelineCheckRecord> check({
    required String sessionId,
    required String repositoryId,
    required String command,
    String? worktreePath,
    String? environmentId,
  }) async {
    checks.add('$sessionId@$worktreePath:$command');
    final verdict = verdicts.isEmpty
        ? VerificationVerdict.pass
        : verdicts.removeAt(0);
    return PipelineCheckRecord(
      verdict: verdict,
      summary: verdict == VerificationVerdict.fail ? '2 tests failed' : 'ok',
      checkedAt: DateTime.utc(2026, 10, 9),
      verificationRunId: 'v${checks.length}',
    );
  }
}
