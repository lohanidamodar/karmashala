import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_automations/pipelines.dart';
import 'package:karmashala_ui/rows.dart' show compactAge;

/// A pipeline run peeked on the dashboard, and — with [stageSessionId] — one
/// of its stages' sessions shown inside the peek.
@immutable
class PipelinePeek {
  const PipelinePeek(this.runId, {this.stageSessionId});

  final String runId;
  final String? stageSessionId;

  @override
  bool operator ==(Object other) =>
      other is PipelinePeek &&
      other.runId == runId &&
      other.stageSessionId == stageSessionId;

  @override
  int get hashCode => Object.hash(runId, stageSessionId);
}

/// **The run peek**: one pipeline run beside the board, as a session's peek
/// is. Opening one closes a session's peek, and the board closes this when
/// a session's opens.
class PipelinePeekController extends Notifier<PipelinePeek?> {
  @override
  PipelinePeek? build() => null;

  void open(String runId) => state = PipelinePeek(runId);

  /// Shows stage session [sessionId] of the peeked run inside the peek.
  void openStage(String runId, String sessionId) =>
      state = PipelinePeek(runId, stageSessionId: sessionId);

  /// From a stage's session back to its run.
  void backToRun() {
    final peek = state;
    if (peek != null) state = PipelinePeek(peek.runId);
  }

  void close() => state = null;
}

final pipelinePeekProvider =
    NotifierProvider<PipelinePeekController, PipelinePeek?>(
      PipelinePeekController.new,
    );

/// "Stage 2 of 3 · 12m · loop 1/2": where [run] is, how long it has taken
/// by [now], and how often it has looped back once it has.
String pipelineRunProgress(PipelineRun run, {required DateTime now}) {
  final stages = run.definition.stages.length;
  final at = (run.current?.stageIndex ?? 0) + 1;
  final took = (run.finishedAt ?? now).difference(run.createdAt);
  String? loop;
  for (final (i, stage) in run.definition.stages.indexed) {
    if (stage.loopBackTo == null) continue;
    final loops = run.loopsFrom(i);
    if (loops > 0) loop = 'loop $loops/${stage.loopCap}';
  }
  return ['Stage $at of $stages', compactAge(took), ?loop].join(' · ');
}

/// What [run] waits on, in a line: a person at a gate or a stage's
/// question ([asking]), checks, a stage's agent — or why it stopped. Null
/// once it finished.
String? pipelineRunWaitingOn(PipelineRun run, {PipelineStageRecord? asking}) {
  final current = run.current;
  final role = current?.role ?? 'the first stage';
  if (asking != null) return 'Waiting on you: ${asking.role} asks something';
  return switch (run.state) {
    PipelineRunState.waiting => 'Waiting on you: approve what $role hands on',
    PipelineRunState.running => switch (current?.state) {
      PipelineStageState.checking => 'Waiting on the checks at $role',
      null || PipelineStageState.starting => 'Waiting for $role to start',
      _ => 'Waiting on $role\'s agent',
    },
    PipelineRunState.failed =>
      'Stuck at $role${run.reason == null ? '' : ': ${run.reason}'}',
    PipelineRunState.stopped => 'Stopped at $role',
    PipelineRunState.finished => null,
  };
}

/// The current stage's last line: what its agent is doing now ([doing]),
/// else the last line of what it last said ([lastAnswer]), else the last
/// line of the answer it handed on. Null when nothing was said.
String? pipelineStageLastLine(
  PipelineStageRecord? record, {
  String? doing,
  String? lastAnswer,
}) {
  if (doing != null && doing.trim().isNotEmpty) return doing.trim();
  for (final text in [lastAnswer, record?.answer]) {
    final lines = (text ?? '')
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty);
    if (lines.isNotEmpty) return lines.last;
  }
  return null;
}
