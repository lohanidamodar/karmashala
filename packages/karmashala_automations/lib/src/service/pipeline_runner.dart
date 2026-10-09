import 'dart:async';

import 'package:karmashala_core/verdicts.dart';

import '../domain/pipeline.dart';
import '../domain/pipeline_run.dart';
import 'pipeline_ports.dart';

/// The most of an artifact a template field carries into a prompt.
const int kPipelineArtifactMaxChars = 40000;

/// **Drives pipeline runs**: starts each stage as a session, waits for its
/// turn, reads its hand-off, holds its gate, loops back, and records every
/// step so a restarted server carries on from the stage it was at.
class PipelineRunner {
  PipelineRunner({
    required this._records,
    required this._launcher,
    required this._watcher,
    required this._evidence,
    required this._now,
    required this._newId,
    void Function(PipelineRun run)? onChanged,
    void Function(String message)? log,
  }) : _onChanged = onChanged ?? _nothing,
       _log = log ?? _ignore;

  final PipelineRecords _records;
  final StageLauncher _launcher;
  final StageWatcher _watcher;
  final StageEvidence _evidence;
  final DateTime Function() _now;
  final String Function() _newId;
  final void Function(PipelineRun run) _onChanged;
  final void Function(String message) _log;

  static void _nothing(PipelineRun _) {}
  static void _ignore(String _) {}

  final _inFlight = <Future<void>>{};

  /// Every stage launch, wait and gate under way has settled — for tests.
  Future<void> idle() async {
    while (_inFlight.isNotEmpty) {
      await Future.wait(_inFlight.toList());
    }
  }

  void _spawn(Future<void> Function() work) {
    late final Future<void> future;
    future = Future<void>(work)
        .catchError((Object error, StackTrace stack) {
          _log('pipeline work failed: $error\n$stack');
        })
        .whenComplete(() => _inFlight.remove(future));
    _inFlight.add(future);
  }

  /// Starts [definition] on [repositoryId] with [input]. Answers once the run
  /// is recorded; its first stage starts behind it.
  PipelineRun start({
    required PipelineDefinition definition,
    required String repositoryId,
    required String input,
    String? startedBySessionId,
    bool byPerson = false,
  }) {
    final refusal = pipelineDefinitionRefusal(definition);
    if (refusal != null) throw ArgumentError(refusal);
    if (input.trim().isEmpty) {
      throw ArgumentError('A pipeline run needs input: what it is to do.');
    }
    final now = _now();
    final run = PipelineRun(
      id: _newId(),
      definition: definition,
      repositoryId: repositoryId,
      input: input.trim(),
      state: PipelineRunState.running,
      startedBySessionId: startedBySessionId,
      byPerson: byPerson,
      createdAt: now,
      updatedAt: now,
    );
    _put(run);
    _spawn(() => _launchStage(run.id, 0));
    return run;
  }

  /// Picks up every run a stopped server left running.
  void resume() {
    for (final run in _records.active()) {
      final record = run.current;
      if (run.state == PipelineRunState.waiting) continue;
      if (record == null) {
        _spawn(() => _launchStage(run.id, 0));
        continue;
      }
      switch (record.state) {
        case PipelineStageState.starting:
          // Whether its session started is unknown; start it again.
          _put(
            run.copyWith(
              records: run.records.take(run.records.length - 1).toList(),
            ),
          );
          _spawn(() => _launchStage(run.id, record.stageIndex));
        case PipelineStageState.running:
          _spawn(() => _watch(run.id, record));
        case PipelineStageState.checking:
          _spawn(() => _gate(run.id, record));
        case PipelineStageState.approval:
          _put(run.copyWith(state: PipelineRunState.waiting));
        case PipelineStageState.done:
        case PipelineStageState.skipped:
          _spawn(() => _next(run.id, record.stageIndex));
        case PipelineStageState.loopedBack:
          final target = run.definition.indexOfKey(
            run.definition.stages[record.stageIndex].loopBackTo ?? '',
          );
          _spawn(() => _launchStage(run.id, target < 0 ? 0 : target));
        case PipelineStageState.failed:
        case PipelineStageState.stopped:
          _fail(run, record.reason ?? 'The stage ended.');
      }
    }
  }

  /// Approves the hand-off [runId] is waiting on, as [handoff] when a person
  /// edited it. [bySessionId] must have started the run, when given.
  PipelineRun approve(String runId, {String? handoff, String? bySessionId}) {
    final run = _require(runId);
    _ownedBy(run, bySessionId);
    final record = run.current;
    if (run.state != PipelineRunState.waiting ||
        record == null ||
        record.state != PipelineStageState.approval) {
      throw StateError('This run is not waiting for an approval.');
    }
    final edited = handoff?.trim();
    final done = record.copyWith(
      state: PipelineStageState.done,
      handoff: edited == null || edited.isEmpty || edited == record.answer
          ? null
          : edited,
    );
    final updated = _put(
      run.withCurrent(done).copyWith(state: PipelineRunState.running),
    );
    _spawn(() => _next(runId, record.stageIndex));
    return updated;
  }

  /// Stops [runId] and its running stage's agent.
  Future<PipelineRun> stop(
    String runId, {
    String reason = 'Stopped by a person.',
    String? bySessionId,
  }) async {
    final run = _require(runId);
    _ownedBy(run, bySessionId);
    if (!run.state.isActive) {
      throw StateError('This run is not running.');
    }
    final record = run.current;
    final stopped = _put(
      (record == null
              ? run
              : run.withCurrent(
                  record.copyWith(
                    state: PipelineStageState.stopped,
                    finishedAt: _now(),
                    reason: reason,
                  ),
                ))
          .copyWith(
            state: PipelineRunState.stopped,
            reason: reason,
            finishedAt: _now(),
          ),
    );
    final session = record?.sessionId;
    if (session != null && record!.state == PipelineStageState.running) {
      try {
        await _watcher.stop(session);
      } on Object catch (error) {
        _log('stopping stage session $session failed: $error');
      }
    }
    return stopped;
  }

  /// Runs [runId]'s failed or stopped stage again, in a new session.
  PipelineRun retry(String runId, {String? bySessionId}) {
    final run = _require(runId);
    _ownedBy(run, bySessionId);
    final record = run.current;
    if (run.state != PipelineRunState.failed &&
        run.state != PipelineRunState.stopped) {
      throw StateError('Only a failed or stopped run has a stage to retry.');
    }
    final index = record?.stageIndex ?? 0;
    final updated = _put(
      run.copyWith(
        state: PipelineRunState.running,
        clearReason: true,
        clearFinished: true,
      ),
    );
    _spawn(() => _launchStage(runId, index));
    return updated;
  }

  /// Passes over [runId]'s current stage, failed, stopped or held at its
  /// gate, and goes on with the next.
  PipelineRun skip(String runId, {String? bySessionId}) {
    final run = _require(runId);
    _ownedBy(run, bySessionId);
    final record = run.current;
    if (record == null ||
        run.state == PipelineRunState.running ||
        run.state == PipelineRunState.finished) {
      throw StateError(
        'Only a failed, stopped or waiting stage can be skipped.',
      );
    }
    final updated = _put(
      run
          .withCurrent(
            record.copyWith(
              state: PipelineStageState.skipped,
              finishedAt: record.finishedAt ?? _now(),
            ),
          )
          .copyWith(
            state: PipelineRunState.running,
            clearReason: true,
            clearFinished: true,
          ),
    );
    _spawn(() => _next(runId, record.stageIndex));
    return updated;
  }

  PipelineRun _require(String runId) =>
      _records.run(runId) ?? (throw ArgumentError('No pipeline run $runId.'));

  void _ownedBy(PipelineRun run, String? bySessionId) {
    if (bySessionId == null) return;
    if (run.startedBySessionId != bySessionId) {
      throw StateError(
        'Only the session that started this pipeline run may act on it.',
      );
    }
  }

  PipelineRun _put(PipelineRun run) {
    final stamped = run.copyWith(updatedAt: _now());
    _records.putRun(stamped);
    _onChanged(stamped);
    return stamped;
  }

  /// The run as stored, while [record] is still its current stage attempt.
  PipelineRun? _stillAt(String runId, PipelineStageRecord record) {
    final run = _records.run(runId);
    final current = run?.current;
    if (run == null ||
        current == null ||
        current.stageIndex != record.stageIndex ||
        current.attempt != record.attempt ||
        !run.state.isActive) {
      return null;
    }
    return run;
  }

  Future<void> _launchStage(String runId, int index, {String? feedback}) async {
    var run = _records.run(runId);
    if (run == null || run.state != PipelineRunState.running) return;
    final stage = run.definition.stages[index];
    final attempt = run.records.where((r) => r.stageIndex == index).length + 1;
    final startedAt = _now();
    String prompt;
    try {
      prompt = await _promptFor(run, index, feedback: feedback);
    } on Object catch (error) {
      prompt = stage.instruction;
      _log('filling ${stage.role} failed: $error');
    }
    var record = PipelineStageRecord(
      stageIndex: index,
      role: stage.role,
      attempt: attempt,
      state: PipelineStageState.starting,
      prompt: prompt,
      startedAt: startedAt,
    );
    run = _put(run.copyWith(records: [...run.records, record]));
    final previous = stage.workspace == PipelineWorkspace.previousWorktree
        ? _previousWorktree(run, index)
        : null;
    if (stage.workspace == PipelineWorkspace.previousWorktree &&
        previous == null) {
      _failStage(run, record, 'No earlier stage left a worktree to work in.');
      return;
    }
    final StageLaunched launched;
    try {
      launched = await _launcher.launch(
        StageLaunch(
          runId: run.id,
          repositoryId: run.repositoryId,
          title: '${stage.role} · ${run.definition.name}',
          prompt: prompt,
          systemPrompt: _systemPromptFor(run, stage),
          workspace: stage.workspace,
          priority: run.byPerson
              ? StagePriority.person
              : StagePriority.background,
          installationId: stage.agentInstallationId,
          modelId: stage.modelId,
          permissionMode: stage.permissionMode,
          worktreePath: previous?.worktreePath,
          environmentId: previous?.environmentId,
          parentSessionId: run.startedBySessionId,
        ),
      );
    } on Object catch (error) {
      final current = _stillAt(runId, record);
      if (current != null) {
        _failStage(current, record, 'Could not start ${stage.role}: $error');
      }
      return;
    }
    final current = _stillAt(runId, record);
    if (current == null) {
      // Stopped while it started: the agent it started is stopped too.
      await _watcher.stop(launched.sessionId).catchError((_) {});
      return;
    }
    record = record.copyWith(
      state: PipelineStageState.running,
      sessionId: launched.sessionId,
      worktreePath: launched.worktreePath ?? previous?.worktreePath,
      environmentId: launched.environmentId ?? previous?.environmentId,
      branch: launched.branch ?? previous?.branch,
    );
    _put(current.withCurrent(record));
    await _watch(runId, record);
  }

  PipelineStageRecord? _previousWorktree(PipelineRun run, int index) {
    for (var i = index - 1; i >= 0; i--) {
      final record = run.latestOf(i);
      if (record?.worktreePath != null) return record;
    }
    return null;
  }

  String _systemPromptFor(PipelineRun run, PipelineStage stage) {
    final lines = [
      'You are the ${stage.role} stage of the pipeline '
          '"${run.definition.name}". Your final answer is handed to the next '
          'stage, so make it complete.',
      if (stage.workspace == PipelineWorkspace.source)
        'Work read-only: change no files in this checkout.',
    ];
    return lines.join('\n');
  }

  Future<String> _promptFor(
    PipelineRun run,
    int index, {
    String? feedback,
  }) async {
    final stage = run.definition.stages[index];
    final fields = pipelineFieldsIn(stage.instruction);
    final artifacts = <String, String>{};
    for (final field in fields.where((f) => f.name == 'artifact')) {
      final stageIndex = _scopeIndex(run, index, field.scope);
      final record = stageIndex == null ? null : run.latestOf(stageIndex);
      final name = field.arg ?? '';
      final ref = record?.artifacts.where((a) => a.answersTo(name)).lastOrNull;
      if (ref == null) {
        artifacts[field.raw] = record == null
            ? ''
            : '(${record.role} showed no artifact named $name.)';
        continue;
      }
      final text = await _evidence.artifactText(ref.id);
      artifacts[field.raw] = text == null
          ? '(${ref.title} from ${record!.role} could not be read.)'
          : '## $name (from ${record!.role})\n\n${_cap(text)}';
    }
    final feedbackText = feedback ?? _feedbackFor(run, index);
    final filled = fillPipelineTemplate(stage.instruction, (field) {
      if (field.scope == 'input') return run.input;
      if (field.scope == 'loop') {
        return switch (field.name) {
          'feedback' => feedbackText,
          'count' =>
            '${run.records.where((r) => r.stageIndex == index).length}',
          _ => null,
        };
      }
      if (field.name == 'artifact') return artifacts[field.raw];
      final stageIndex = _scopeIndex(run, index, field.scope);
      if (stageIndex == null) return null;
      final record = run.latestOf(stageIndex);
      if (record == null) return '';
      return switch (field.name) {
        'answer' => record.handedOn,
        'artifacts' =>
          record.artifacts.isEmpty
              ? '(none)'
              : record.artifacts.map((a) => a.path ?? a.title).join('\n'),
        'worktree' => record.worktreePath ?? '(no worktree)',
        'branch' => record.branch ?? '(no branch)',
        'checks' =>
          record.check == null
              ? '(no checks ran)'
              : '${record.check!.label}: ${record.check!.summary}',
        _ => null,
      };
    });
    final parts = [filled.trim()];
    // The previous stage's answer is always handed on, named or not.
    if (index > 0) {
      final previous = run.latestOf(index - 1);
      final prevKey = run.definition.stages[index - 1].key;
      final named = fields.any(
        (f) =>
            f.name == 'answer' && (f.scope == 'previous' || f.scope == prevKey),
      );
      if (!named && previous != null && previous.handedOn.trim().isNotEmpty) {
        parts.add('## Hand-off from ${previous.role}\n\n${previous.handedOn}');
      }
    }
    final usesFeedback = fields.any(
      (f) => f.scope == 'loop' && f.name == 'feedback',
    );
    if (!usesFeedback && feedbackText.isNotEmpty) parts.add(feedbackText);
    return parts.where((p) => p.isNotEmpty).join('\n\n');
  }

  int? _scopeIndex(PipelineRun run, int index, String scope) {
    if (scope == 'previous') return index > 0 ? index - 1 : null;
    final found = run.definition.indexOfKey(scope);
    return found < 0 ? null : found;
  }

  /// Why the run came back to [index], when the attempt before this one sent
  /// it here.
  String _feedbackFor(PipelineRun run, int index) {
    final last = run.current;
    if (last == null || last.state != PipelineStageState.loopedBack) return '';
    final from = run.definition.stages[last.stageIndex];
    if (run.definition.indexOfKey(from.loopBackTo ?? '') != index) return '';
    return '## Sent back by ${last.role}\n\n${last.reason ?? ''}'.trim();
  }

  static String _cap(String text) => text.length <= kPipelineArtifactMaxChars
      ? text
      : '${text.substring(0, kPipelineArtifactMaxChars)}\n…(cut)';

  Future<void> _watch(String runId, PipelineStageRecord record) async {
    final turn = await _watcher.turnOf(
      record.sessionId!,
      since: record.startedAt ?? _now(),
    );
    final run = _stillAt(runId, record);
    if (run == null || run.current!.state != PipelineStageState.running) {
      return;
    }
    final failure = turn.failure;
    if (failure != null) {
      _failStage(run, run.current!, failure);
      return;
    }
    List<PipelineArtifactRef> artifacts;
    try {
      artifacts = await _evidence.artifactsOf(record.sessionId!);
    } on Object catch (error) {
      _log('reading ${record.role} artifacts failed: $error');
      artifacts = const [];
    }
    final latest = _stillAt(runId, record);
    if (latest == null) return;
    final answered = latest.current!.copyWith(
      answer: turn.answer ?? '',
      artifacts: artifacts,
      finishedAt: _now(),
    );
    _put(latest.withCurrent(answered));
    await _gate(runId, answered);
  }

  Future<void> _gate(String runId, PipelineStageRecord record) async {
    var run = _stillAt(runId, record);
    if (run == null) return;
    final stage = run.definition.stages[record.stageIndex];
    var current = run.current!;
    String? sendBack;
    if (stage.gate == PipelineGateKind.check) {
      current = current.copyWith(state: PipelineStageState.checking);
      run = _put(run.withCurrent(current));
      PipelineCheckRecord check;
      try {
        check = await _evidence.check(
          sessionId: current.sessionId!,
          repositoryId: run.repositoryId,
          command: stage.checkCommand,
          worktreePath: current.worktreePath,
          environmentId: current.environmentId,
        );
      } on Object catch (error) {
        check = PipelineCheckRecord(
          verdict: _inconclusive,
          summary: 'The checks could not run: $error',
          checkedAt: _now(),
        );
      }
      run = _stillAt(runId, record);
      if (run == null) return;
      current = run.current!.copyWith(check: check);
      run = _put(run.withCurrent(current));
      if (!check.passed) {
        sendBack = 'Checks ${check.label}.\n\n${check.summary}'.trim();
      }
    }
    if (sendBack == null &&
        stage.loopBackTo != null &&
        pipelineVerdictOf(current.answer) == PipelineVerdict.fail) {
      sendBack = current.answer ?? '';
    }
    if (sendBack != null) {
      final target = run.definition.indexOfKey(stage.loopBackTo ?? '');
      if (target < 0) {
        _failStage(run, current, sendBack);
        return;
      }
      final loops = run.loopsFrom(record.stageIndex);
      if (loops >= stage.loopCap) {
        _failStage(
          run,
          current,
          '${stage.role} still fails after $loops loop-back'
          '${loops == 1 ? '' : 's'}.\n\n$sendBack',
        );
        return;
      }
      _put(
        run.withCurrent(
          current.copyWith(
            state: PipelineStageState.loopedBack,
            reason: sendBack,
          ),
        ),
      );
      await _launchStage(runId, target);
      return;
    }
    if (stage.gate == PipelineGateKind.approval) {
      _put(
        run
            .withCurrent(current.copyWith(state: PipelineStageState.approval))
            .copyWith(state: PipelineRunState.waiting),
      );
      return;
    }
    _put(run.withCurrent(current.copyWith(state: PipelineStageState.done)));
    await _next(runId, record.stageIndex);
  }

  Future<void> _next(String runId, int index) async {
    final run = _records.run(runId);
    if (run == null || run.state != PipelineRunState.running) return;
    if (index + 1 < run.definition.stages.length) {
      await _launchStage(runId, index + 1);
      return;
    }
    _put(run.copyWith(state: PipelineRunState.finished, finishedAt: _now()));
  }

  void _failStage(PipelineRun run, PipelineStageRecord record, String reason) {
    _fail(
      run.withCurrent(
        record.copyWith(
          state: PipelineStageState.failed,
          finishedAt: _now(),
          reason: reason,
        ),
      ),
      reason,
    );
  }

  void _fail(PipelineRun run, String reason) {
    _put(
      run.copyWith(
        state: PipelineRunState.failed,
        reason: reason,
        finishedAt: _now(),
      ),
    );
  }
}

const _inconclusive = VerificationVerdict.inconclusive;
