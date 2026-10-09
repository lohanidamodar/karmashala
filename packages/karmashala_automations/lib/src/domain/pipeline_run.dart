import 'package:karmashala_core/verdicts.dart';
import 'package:karmashala_verification/verification.dart' show CodeIdentity;

import 'pipeline.dart';

/// Where a pipeline run is.
enum PipelineRunState {
  running('running'),

  /// Held at an approval gate for a person.
  waiting('waiting'),
  finished('finished'),

  /// A stage failed; Retry stage or Skip carries it on.
  failed('failed'),

  /// Stopped by a person or a parent; Retry stage carries it on.
  stopped('stopped');

  const PipelineRunState(this.storedName);

  final String storedName;

  bool get isOver => this == finished;
  bool get isActive => this == running || this == waiting;

  static PipelineRunState fromStored(Object? stored) => values.firstWhere(
    (s) => s.storedName == stored,
    orElse: () => PipelineRunState.failed,
  );
}

/// Where one attempt at a stage is.
enum PipelineStageState {
  /// Its session is being started.
  starting('starting'),
  running('running'),

  /// Its gate's checks are running.
  checking('checking'),

  /// Done, held at its approval gate.
  approval('approval'),
  done('done'),
  failed('failed'),
  skipped('skipped'),
  stopped('stopped'),

  /// Done, but sent back by its own verdict or checks.
  loopedBack('looped_back');

  const PipelineStageState(this.storedName);

  final String storedName;

  bool get isSettled =>
      this == done ||
      this == failed ||
      this == skipped ||
      this == stopped ||
      this == loopedBack;

  static PipelineStageState fromStored(Object? stored) => values.firstWhere(
    (s) => s.storedName == stored,
    orElse: () => PipelineStageState.failed,
  );
}

/// An artifact a stage's session showed.
class PipelineArtifactRef {
  const PipelineArtifactRef({
    required this.id,
    required this.title,
    this.path,
    this.revision = 1,
  });

  final String id;
  final String title;
  final String? path;
  final int revision;

  /// Whether a template's `artifact:<name>` means this one: its title or its
  /// file's name, case-insensitively.
  bool answersTo(String name) {
    final wanted = name.trim().toLowerCase();
    if (title.toLowerCase() == wanted) return true;
    final file = path?.split(RegExp(r'[\\/]')).last.toLowerCase();
    return file == wanted;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'path': ?path,
    'revision': revision,
  };

  static PipelineArtifactRef? fromJson(Object? json) {
    if (json is! Map || json['id'] is! String) return null;
    return PipelineArtifactRef(
      id: json['id'] as String,
      title: json['title'] as String? ?? '',
      path: json['path'] as String?,
      revision: (json['revision'] as num?)?.toInt() ?? 1,
    );
  }
}

/// What a check gate read: the verdict, the verification run that holds it,
/// and which code it was taken on.
class PipelineCheckRecord {
  const PipelineCheckRecord({
    required this.verdict,
    required this.summary,
    required this.checkedAt,
    this.verificationRunId,
    this.identity,
  });

  final VerificationVerdict verdict;
  final String summary;
  final DateTime checkedAt;
  final String? verificationRunId;
  final CodeIdentity? identity;

  /// The code moved while the checks ran, so the reading describes neither.
  bool get stale => identity?.changedDuringRun ?? false;

  bool get passed => verdict == VerificationVerdict.pass && !stale;

  String get label {
    if (stale) return 'stale: the code changed while it ran';
    return switch (verdict) {
      VerificationVerdict.pass => 'passed',
      VerificationVerdict.fail => 'failed',
      VerificationVerdict.inconclusive => 'inconclusive',
    };
  }

  Map<String, Object?> toJson() => {
    'verdict': verdict.name,
    'summary': summary,
    'checkedAt': checkedAt.toUtc().toIso8601String(),
    'verificationRunId': ?verificationRunId,
    if (identity != null) 'identity': identity!.toJson(),
  };

  static PipelineCheckRecord? fromJson(Object? json) {
    if (json is! Map) return null;
    return PipelineCheckRecord(
      verdict: VerificationVerdict.values.firstWhere(
        (v) => v.name == json['verdict'],
        orElse: () => VerificationVerdict.inconclusive,
      ),
      summary: json['summary'] as String? ?? '',
      checkedAt:
          DateTime.tryParse(json['checkedAt'] as String? ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      verificationRunId: json['verificationRunId'] as String?,
      identity: CodeIdentity.fromJson(json['identity']),
    );
  }
}

/// One attempt at one stage: its session and everything it handed on.
class PipelineStageRecord {
  const PipelineStageRecord({
    required this.stageIndex,
    required this.role,
    required this.attempt,
    required this.state,
    this.sessionId,
    this.prompt,
    this.answer,
    this.handoff,
    this.artifacts = const [],
    this.worktreePath,
    this.environmentId,
    this.branch,
    this.check,
    this.startedAt,
    this.finishedAt,
    this.reason,
  });

  final int stageIndex;
  final String role;

  /// 1 for the first run of this stage, counting loop-backs and retries.
  final int attempt;
  final PipelineStageState state;
  final String? sessionId;

  /// The instruction as it was sent, fields filled.
  final String? prompt;

  /// The agent's final answer.
  final String? answer;

  /// The hand-off as a person edited it at the approval gate.
  final String? handoff;
  final List<PipelineArtifactRef> artifacts;
  final String? worktreePath;
  final String? environmentId;
  final String? branch;
  final PipelineCheckRecord? check;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  /// Why it failed, stopped or looped back.
  final String? reason;

  /// What the next stage receives as this stage's answer.
  String get handedOn => handoff ?? answer ?? '';

  Duration? get duration => startedAt == null
      ? null
      : (finishedAt ?? DateTime.now().toUtc()).difference(startedAt!);

  PipelineStageRecord copyWith({
    PipelineStageState? state,
    String? sessionId,
    String? prompt,
    String? answer,
    String? handoff,
    List<PipelineArtifactRef>? artifacts,
    String? worktreePath,
    String? environmentId,
    String? branch,
    PipelineCheckRecord? check,
    DateTime? startedAt,
    DateTime? finishedAt,
    String? reason,
  }) => PipelineStageRecord(
    stageIndex: stageIndex,
    role: role,
    attempt: attempt,
    state: state ?? this.state,
    sessionId: sessionId ?? this.sessionId,
    prompt: prompt ?? this.prompt,
    answer: answer ?? this.answer,
    handoff: handoff ?? this.handoff,
    artifacts: artifacts ?? this.artifacts,
    worktreePath: worktreePath ?? this.worktreePath,
    environmentId: environmentId ?? this.environmentId,
    branch: branch ?? this.branch,
    check: check ?? this.check,
    startedAt: startedAt ?? this.startedAt,
    finishedAt: finishedAt ?? this.finishedAt,
    reason: reason ?? this.reason,
  );

  Map<String, Object?> toJson() => {
    'stageIndex': stageIndex,
    'role': role,
    'attempt': attempt,
    'state': state.storedName,
    'sessionId': ?sessionId,
    'prompt': ?prompt,
    'answer': ?answer,
    'handoff': ?handoff,
    if (artifacts.isNotEmpty)
      'artifacts': [for (final a in artifacts) a.toJson()],
    'worktreePath': ?worktreePath,
    'environmentId': ?environmentId,
    'branch': ?branch,
    if (check != null) 'check': check!.toJson(),
    'startedAt': ?startedAt?.toUtc().toIso8601String(),
    'finishedAt': ?finishedAt?.toUtc().toIso8601String(),
    'reason': ?reason,
  };

  static PipelineStageRecord fromJson(Map<String, Object?> json) =>
      PipelineStageRecord(
        stageIndex: (json['stageIndex'] as num?)?.toInt() ?? 0,
        role: json['role'] as String? ?? '',
        attempt: (json['attempt'] as num?)?.toInt() ?? 1,
        state: PipelineStageState.fromStored(json['state']),
        sessionId: json['sessionId'] as String?,
        prompt: json['prompt'] as String?,
        answer: json['answer'] as String?,
        handoff: json['handoff'] as String?,
        artifacts: [
          for (final a in (json['artifacts'] as List<Object?>?) ?? const [])
            ?PipelineArtifactRef.fromJson(a),
        ],
        worktreePath: json['worktreePath'] as String?,
        environmentId: json['environmentId'] as String?,
        branch: json['branch'] as String?,
        check: PipelineCheckRecord.fromJson(json['check']),
        startedAt: _date(json['startedAt']),
        finishedAt: _date(json['finishedAt']),
        reason: json['reason'] as String?,
      );
}

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

/// One run of a pipeline: a snapshot of its definition, what it was started
/// with, and a record per stage attempt, oldest first.
class PipelineRun {
  const PipelineRun({
    required this.id,
    required this.definition,
    required this.repositoryId,
    required this.input,
    required this.state,
    required this.createdAt,
    required this.updatedAt,
    this.records = const [],
    this.startedBySessionId,
    this.byPerson = false,
    this.finishedAt,
    this.reason,
  });

  final String id;

  /// As it was when the run started: editing the pipeline later changes
  /// nothing here.
  final PipelineDefinition definition;
  final String repositoryId;
  final String input;
  final PipelineRunState state;
  final List<PipelineStageRecord> records;

  /// The session that started it over MCP, which alone may approve its gates.
  final String? startedBySessionId;

  /// A person started it, so its stages launch ahead of background work.
  final bool byPerson;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? finishedAt;
  final String? reason;

  PipelineStageRecord? get current => records.isEmpty ? null : records.last;

  PipelineStage? get currentStage {
    final record = current;
    return record == null ? null : definition.stages[record.stageIndex];
  }

  /// The latest attempt at stage [index], if it has run.
  PipelineStageRecord? latestOf(int index) {
    for (final record in records.reversed) {
      if (record.stageIndex == index) return record;
    }
    return null;
  }

  /// How many times stage [index] has sent the run back.
  int loopsFrom(int index) => records
      .where(
        (r) =>
            r.stageIndex == index && r.state == PipelineStageState.loopedBack,
      )
      .length;

  PipelineRun copyWith({
    PipelineRunState? state,
    List<PipelineStageRecord>? records,
    DateTime? updatedAt,
    DateTime? finishedAt,
    bool clearFinished = false,
    String? reason,
    bool clearReason = false,
  }) => PipelineRun(
    id: id,
    definition: definition,
    repositoryId: repositoryId,
    input: input,
    state: state ?? this.state,
    records: records ?? this.records,
    startedBySessionId: startedBySessionId,
    byPerson: byPerson,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    finishedAt: clearFinished ? null : finishedAt ?? this.finishedAt,
    reason: clearReason ? null : reason ?? this.reason,
  );

  /// [records] with its last one replaced by [record].
  PipelineRun withCurrent(PipelineStageRecord record) =>
      copyWith(records: [...records.take(records.length - 1), record]);

  Map<String, Object?> toJson() => {
    'id': id,
    'definition': definition.toJson(),
    'repositoryId': repositoryId,
    'input': input,
    'state': state.storedName,
    'records': [for (final r in records) r.toJson()],
    'startedBySessionId': ?startedBySessionId,
    'byPerson': byPerson,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'finishedAt': ?finishedAt?.toUtc().toIso8601String(),
    'reason': ?reason,
  };

  static PipelineRun fromJson(Map<String, Object?> json) => PipelineRun(
    id: json['id']! as String,
    definition: PipelineDefinition.fromJson(
      (json['definition'] as Map).cast<String, Object?>(),
    ),
    repositoryId: json['repositoryId'] as String? ?? '',
    input: json['input'] as String? ?? '',
    state: PipelineRunState.fromStored(json['state']),
    records: [
      for (final r in (json['records'] as List<Object?>?) ?? const [])
        if (r is Map) PipelineStageRecord.fromJson(r.cast<String, Object?>()),
    ],
    startedBySessionId: json['startedBySessionId'] as String?,
    byPerson: json['byPerson'] == true,
    createdAt: _date(json['createdAt']) ?? DateTime.utc(1970),
    updatedAt: _date(json['updatedAt']) ?? DateTime.utc(1970),
    finishedAt: _date(json['finishedAt']),
    reason: json['reason'] as String?,
  );
}
