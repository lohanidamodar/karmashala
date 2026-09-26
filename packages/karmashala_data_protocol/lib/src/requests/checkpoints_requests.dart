part of '../data_request.dart';

// Checkpoints (metadata over git objects), verification runs (rows over
// evidence files) and fan-out comparisons.

DataRequest<Object?>? _checkpointsRequestFromJson(
  String kind,
  _Arguments args,
) => switch (kind) {
  CheckpointsForSession.name => CheckpointsForSession(args.string('sessionId')),
  CheckpointGet.name => CheckpointGet(args.string('id')),
  CheckpointsRecent.name => CheckpointsRecent(args.optionalInt('limit') ?? 50),
  CheckpointRecord.name => CheckpointRecord(
    args.value('checkpoint', checkpointFromJson),
  ),
  CheckpointRelabel.name => CheckpointRelabel(
    args.string('id'),
    args.string('label'),
  ),
  CheckpointsPrune.name => CheckpointsPrune._from(args),
  CheckpointCapture.name => CheckpointCapture(
    args.string('sessionId'),
    label: args.optionalString('label'),
    decidedBy: args.optionalString('decidedBy'),
    decidedBySessionId: args.optionalString('decidedBySessionId'),
  ),
  CheckpointCaptureBase.name => CheckpointCaptureBase(
    args.value('checkout', environmentPathFromJson),
    runId: args.string('runId'),
    label: args.string('label'),
  ),
  CheckpointDiff.name => CheckpointDiff(args.string('id')),
  CheckpointRestore.name => CheckpointRestore(
    args.string('id'),
    confirm: args.boolean('confirm', orElse: false),
    paths: args.strings('paths', orEmpty: true),
  ),
  CheckpointSkips.name => const CheckpointSkips(),
  VerificationRuns.name => const VerificationRuns(),
  VerificationRecent.name => VerificationRecent(
    limit: args.optionalInt('limit') ?? 50,
    sessionId: args.optionalString('sessionId'),
  ),
  VerificationGet.name => VerificationGet(args.string('id')),
  VerificationMatching.name => VerificationMatching(args.string('prefix')),
  VerificationStart.name => VerificationStart(
    args.value('run', verificationRunFromJson),
  ),
  VerificationStepAdd.name => VerificationStepAdd(
    args.string('runId'),
    args.value('step', verificationStepFromJson),
  ),
  VerificationArtifactAdd.name => VerificationArtifactAdd(
    args.value('artifact', verificationArtifactFromJson),
  ),
  VerificationFinish.name => VerificationFinish(
    args.string('id'),
    verdict:
        VerificationVerdict.parse(args.string('verdict')) ??
        (throw DataRefused.invalid('$kind: "verdict" is not a verdict')),
    reason: args.optionalString('reason'),
    producedBySessionId: args.optionalString('producedBySessionId'),
  ),
  VerificationRecord.name => VerificationRecord(
    args.value('run', verificationRunFromJson),
  ),
  VerificationAttach.name => VerificationAttach(
    args.string('id'),
    args.optionalString('sessionId'),
  ),
  VerificationDelete.name => VerificationDelete(args.string('id')),
  ComparisonsList.name => const ComparisonsList(),
  ComparisonCreate.name => ComparisonCreate(
    args.value('comparison', comparisonFromJson),
  ),
  ComparisonRecordDiff.name => ComparisonRecordDiff(
    args.string('candidateId'),
    args.value('diff', diffStatFromJson),
  ),
  ComparisonWorktreeRemoved.name => ComparisonWorktreeRemoved(
    args.string('candidateId'),
  ),
  ComparisonSetWinner.name => ComparisonSetWinner(
    args.string('id'),
    args.optionalString('candidateId'),
  ),
  ComparisonClose.name => ComparisonClose(
    args.string('id'),
    outcome: ComparisonOutcome.values.firstWhere(
      (o) => o.name == args.string('outcome'),
      orElse: () => throw DataRefused.invalid('$kind: unknown outcome'),
    ),
    winnerCandidateId: args.optionalString('winnerCandidateId'),
    mergedCommit: args.optionalString('mergedCommit'),
  ),
  ComparisonArchive.name => ComparisonArchive(
    args.string('id'),
    archived: args.boolean('archived'),
  ),
  _ => null,
};

// Checkpoints.

/// A request about the checkpoint index. Unbounded, so asked for per session
/// rather than copied.
sealed class CheckpointsRequest<R> extends DataRequest<R> {
  const CheckpointsRequest();
}

/// Every checkpoint of [sessionId], oldest first.
final class CheckpointsForSession extends CheckpointsRequest<List<Checkpoint>> {
  const CheckpointsForSession(this.sessionId);

  static const String name = 'checkpoints.forSession';

  final String sessionId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'sessionId': sessionId};

  @override
  Object? resultToJson(List<Checkpoint> result) => [
    for (final c in result) checkpointToJson(c),
  ];

  @override
  List<Checkpoint> resultFromJson(Object? json) => _decode(
    kind,
    () => [for (final item in _objects(json, kind)) checkpointFromJson(item)],
  );
}

/// The newest [limit] checkpoints across every session, newest first.
final class CheckpointsRecent extends CheckpointsRequest<List<Checkpoint>> {
  const CheckpointsRecent([this.limit = 50]);

  static const String name = 'checkpoints.recent';

  final int limit;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'limit': limit};

  @override
  Object? resultToJson(List<Checkpoint> result) => [
    for (final c in result) checkpointToJson(c),
  ];

  @override
  List<Checkpoint> resultFromJson(Object? json) => _decode(
    kind,
    () => [for (final item in _objects(json, kind)) checkpointFromJson(item)],
  );
}

final class CheckpointGet extends CheckpointsRequest<Checkpoint?> {
  const CheckpointGet(this.id);

  static const String name = 'checkpoints.get';

  final String id;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id};

  @override
  Object? resultToJson(Checkpoint? result) =>
      result == null ? null : checkpointToJson(result);

  @override
  Checkpoint? resultFromJson(Object? json) => json == null
      ? null
      : _decode(kind, () => checkpointFromJson(_object(json, kind)));
}

/// Records a capture — one request per checkpoint. The server numbers it in
/// its session and answers it as stored.
final class CheckpointRecord extends _CheckpointAnswer {
  const CheckpointRecord(this.checkpoint);

  static const String name = 'checkpoints.record';

  final Checkpoint checkpoint;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'checkpoint': checkpointToJson(checkpoint),
  };
}

final class CheckpointRelabel extends _CheckpointAnswer {
  const CheckpointRelabel(this.id, this.label);

  static const String name = 'checkpoints.relabel';

  final String id;
  final String label;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id, 'label': label};
}

/// Drops [dropIds] of [sessionId] and re-points the survivors at the commits
/// the prune rewrote, in one transaction.
final class CheckpointsPrune extends CheckpointsRequest<DataAck> {
  const CheckpointsPrune(
    this.sessionId, {
    required this.dropIds,
    required this.rewritten,
  });

  factory CheckpointsPrune._from(_Arguments args) {
    final rewritten = <String, ({String commit, String? parent})>{};
    for (final row in args.objects('rewritten', (json) => json)) {
      final id = row['id'];
      final commit = row['commit'];
      final parent = row['parent'];
      if (id is! String || commit is! String || parent is! String?) {
        throw DataRefused.invalid('$name: "rewritten" is out of shape');
      }
      rewritten[id] = (commit: commit, parent: parent);
    }
    return CheckpointsPrune(
      args.string('sessionId'),
      dropIds: args.strings('dropIds'),
      rewritten: rewritten,
    );
  }

  static const String name = 'checkpoints.prune';

  final String sessionId;
  final List<String> dropIds;
  final Map<String, ({String commit, String? parent})> rewritten;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'sessionId': sessionId,
    'dropIds': dropIds,
    'rewritten': [
      for (final entry in rewritten.entries)
        {
          'id': entry.key,
          'commit': entry.value.commit,
          'parent': entry.value.parent,
        },
    ],
  };

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

sealed class _CheckpointAnswer extends CheckpointsRequest<Checkpoint> {
  const _CheckpointAnswer();

  @override
  Object? resultToJson(Checkpoint result) => checkpointToJson(result);

  @override
  Checkpoint resultFromJson(Object? json) =>
      _decode(kind, () => checkpointFromJson(_object(json, kind)));
}

// Checkpoint work: what runs git in the checkout (slice 2b). The server's
// recorder does it, so a client never runs `CheckpointService` itself. Each
// is answered when its work is done — by id, out of order — and every row it
// writes is told as a change ([CheckpointRecorded], [CheckpointsPruned]).
// A checkout the server cannot reach (SSH) is refused `invalid`, in words.

/// A request the server's checkpoint recorder answers when its git work is
/// done.
sealed class CheckpointWorkRequest<R> extends DataRequest<R> {
  const CheckpointWorkRequest();
}

/// Captures every working tree [sessionId] works in, now, through the
/// recorder's queue for that session — the panel's "Capture now" and
/// `checkpoint_capture`. Answers the first checkpoint taken (its own
/// checkout's when that moved), or null when nothing moved or there is no
/// repository. A [label]led one is filed to the decision record as decided
/// by [decidedBy] (null: not recorded).
final class CheckpointCapture extends CheckpointWorkRequest<Checkpoint?> {
  const CheckpointCapture(
    this.sessionId, {
    this.label,
    this.decidedBy,
    this.decidedBySessionId,
  });

  static const String name = 'checkpoints.capture';

  final String sessionId;
  final String? label;
  final String? decidedBy;
  final String? decidedBySessionId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'sessionId': sessionId,
    'label': ?label,
    'decidedBy': ?decidedBy,
    'decidedBySessionId': ?decidedBySessionId,
  };

  @override
  Object? resultToJson(Checkpoint? result) =>
      result == null ? null : checkpointToJson(result);

  @override
  Checkpoint? resultFromJson(Object? json) => json == null
      ? null
      : _decode(kind, () => checkpointFromJson(_object(json, kind)));
}

/// The base of an automation run the client starts itself (a checkout the
/// server's own runner does not start in): [checkout] recorded under
/// [runId], even when unchanged, so undo has a point to restore to.
final class CheckpointCaptureBase extends CheckpointWorkRequest<Checkpoint?> {
  const CheckpointCaptureBase(
    this.checkout, {
    required this.runId,
    required this.label,
  });

  static const String name = 'checkpoints.captureBase';

  final EnvironmentPath checkout;
  final String runId;
  final String label;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'checkout': environmentPathToJson(checkout),
    'runId': runId,
    'label': label,
  };

  @override
  Object? resultToJson(Checkpoint? result) =>
      result == null ? null : checkpointToJson(result);

  @override
  Checkpoint? resultFromJson(Object? json) => json == null
      ? null
      : _decode(kind, () => checkpointFromJson(_object(json, kind)));
}

/// The unified diff checkpoint [id] is: what changed between the checkpoint
/// before it (or the commit it was taken on) and it. Refused `notFound` for
/// an unknown id.
final class CheckpointDiff extends CheckpointWorkRequest<String> {
  const CheckpointDiff(this.id);

  static const String name = 'checkpoints.diff';

  final String id;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id};

  @override
  Object? resultToJson(String result) => result;

  @override
  String resultFromJson(Object? json) =>
      json is String ? json : _badAnswer(kind);
}

/// Puts checkpoint [id]'s working tree back — every file, or only [paths] —
/// taking a safety checkpoint of the current tree first. A tree that moved
/// since its last checkpoint is answered with the conflict (and the safety
/// checkpoint) unless [confirm]; [CheckpointRestoreAnswer.outcomeOrThrow]
/// throws it as the service did.
final class CheckpointRestore
    extends CheckpointWorkRequest<CheckpointRestoreAnswer> {
  const CheckpointRestore(
    this.id, {
    this.confirm = false,
    this.paths = const [],
  });

  static const String name = 'checkpoints.restore';

  final String id;
  final bool confirm;
  final List<String> paths;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'id': id,
    'confirm': confirm,
    if (paths.isNotEmpty) 'paths': paths,
  };

  @override
  Object? resultToJson(CheckpointRestoreAnswer result) => result.toJson();

  @override
  CheckpointRestoreAnswer resultFromJson(Object? json) => _decode(
    kind,
    () => CheckpointRestoreAnswer.fromJson(_object(json, kind)),
  );
}

/// Why each session has no automatic checkpoints right now (session id →
/// the reason, in the panel's words), as the recorder last found. Kept after
/// by [CheckpointSkipChanged].
final class CheckpointSkips extends CheckpointWorkRequest<Map<String, String>> {
  const CheckpointSkips();

  static const String name = 'checkpoints.skips';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(Map<String, String> result) => result;

  @override
  Map<String, String> resultFromJson(Object? json) => _decode(kind, () {
    final map = _object(json, kind);
    return {for (final e in map.entries) e.key: e.value! as String};
  });
}

// Verification runs.

/// A request about verification runs. A client copies every run's header;
/// steps and evidence rows are asked for.
sealed class VerificationRequest<R> extends DataRequest<R> {
  const VerificationRequest();
}

/// Every run's header (no steps, no evidence), newest first.
final class VerificationRuns extends _VerificationRunsAnswer {
  const VerificationRuns();

  static const String name = 'verification.runs';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};
}

/// The newest [limit] runs — of [sessionId] when given — whole.
final class VerificationRecent extends _VerificationRunsAnswer {
  const VerificationRecent({this.limit = 50, this.sessionId});

  static const String name = 'verification.list';

  final int limit;
  final String? sessionId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'limit': limit,
    'sessionId': ?sessionId,
  };
}

/// Headers of the runs whose id starts with [prefix] — to refuse, not guess.
final class VerificationMatching extends _VerificationRunsAnswer {
  const VerificationMatching(this.prefix);

  static const String name = 'verification.matching';

  final String prefix;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'prefix': prefix};
}

/// One run whole, or null.
final class VerificationGet extends VerificationRequest<VerificationRun?> {
  const VerificationGet(this.id);

  static const String name = 'verification.get';

  final String id;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id};

  @override
  Object? resultToJson(VerificationRun? result) =>
      result == null ? null : verificationRunToJson(result);

  @override
  VerificationRun? resultFromJson(Object? json) => json == null
      ? null
      : _decode(kind, () => verificationRunFromJson(_object(json, kind)));
}

/// Opens a run the client is about to record into. Refused for a taken id.
final class VerificationStart extends _VerificationRunAnswer {
  const VerificationStart(this.run);

  static const String name = 'verification.start';

  final VerificationRun run;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'run': verificationRunToJson(verificationHeaderOf(run)),
  };
}

final class VerificationStepAdd extends _VerificationAck {
  const VerificationStepAdd(this.runId, this.step);

  static const String name = 'verification.step';

  final String runId;
  final VerificationStep step;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'runId': runId,
    'step': verificationStepToJson(step),
  };
}

/// An evidence file the client already wrote beside the store.
final class VerificationArtifactAdd extends _VerificationAck {
  const VerificationArtifactAdd(this.artifact);

  static const String name = 'verification.artifact';

  final VerificationArtifact artifact;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'artifact': verificationArtifactToJson(artifact),
  };
}

/// Closes a run with its verdict at the server's clock; answers it whole. A
/// producer that is null keeps the one the start recorded.
final class VerificationFinish extends _VerificationRunAnswer {
  const VerificationFinish(
    this.id, {
    required this.verdict,
    this.reason,
    this.producedBySessionId,
  });

  static const String name = 'verification.finish';

  final String id;
  final VerificationVerdict verdict;
  final String? reason;
  final String? producedBySessionId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'id': id,
    'verdict': verdict.name,
    'reason': ?reason,
    'producedBySessionId': ?producedBySessionId,
  };
}

/// A finished run recorded whole — a gate Karmashala ran itself.
final class VerificationRecord extends _VerificationRunAnswer {
  const VerificationRecord(this.run);

  static const String name = 'verification.record';

  final VerificationRun run;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'run': verificationRunToJson(run)};
}

/// Files run [id] under [sessionId], or under none.
final class VerificationAttach extends _VerificationRunAnswer {
  const VerificationAttach(this.id, this.sessionId);

  static const String name = 'verification.attach';

  final String id;
  final String? sessionId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id, 'sessionId': sessionId};
}

/// Forgets a run and its rows; its evidence files are the client's to remove.
final class VerificationDelete extends _VerificationAck {
  const VerificationDelete(this.id);

  static const String name = 'verification.delete';

  final String id;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id};
}

sealed class _VerificationRunsAnswer
    extends VerificationRequest<List<VerificationRun>> {
  const _VerificationRunsAnswer();

  @override
  Object? resultToJson(List<VerificationRun> result) => [
    for (final run in result) verificationRunToJson(run),
  ];

  @override
  List<VerificationRun> resultFromJson(Object? json) => _decode(
    kind,
    () => [
      for (final item in _objects(json, kind)) verificationRunFromJson(item),
    ],
  );
}

sealed class _VerificationRunAnswer
    extends VerificationRequest<VerificationRun> {
  const _VerificationRunAnswer();

  @override
  Object? resultToJson(VerificationRun result) => verificationRunToJson(result);

  @override
  VerificationRun resultFromJson(Object? json) =>
      _decode(kind, () => verificationRunFromJson(_object(json, kind)));
}

sealed class _VerificationAck extends VerificationRequest<DataAck> {
  const _VerificationAck();

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

// Fan-out comparisons.

/// A request about fan-out comparisons; each write answers the comparison
/// whole, candidates included.
sealed class ComparisonsRequest<R> extends DataRequest<R> {
  const ComparisonsRequest();
}

/// Every comparison, archived ones too, newest first.
final class ComparisonsList extends ComparisonsRequest<List<Comparison>> {
  const ComparisonsList();

  static const String name = 'comparisons.list';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(List<Comparison> result) => [
    for (final c in result) comparisonToJson(c),
  ];

  @override
  List<Comparison> resultFromJson(Object? json) => _decode(
    kind,
    () => [for (final item in _objects(json, kind)) comparisonFromJson(item)],
  );
}

/// Records a fan-out and every candidate in one transaction. Refused for a
/// taken id, an unknown checkout, or candidates out of shape.
final class ComparisonCreate extends _ComparisonAnswer {
  const ComparisonCreate(this.comparison);

  static const String name = 'comparisons.create';

  final Comparison comparison;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'comparison': comparisonToJson(comparison),
  };
}

/// What a candidate's worktree showed when last read.
final class ComparisonRecordDiff extends _ComparisonAnswer {
  const ComparisonRecordDiff(this.candidateId, this.diff);

  static const String name = 'comparisons.recordDiff';

  final String candidateId;
  final CandidateDiffStat diff;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'candidateId': candidateId,
    'diff': diffStatToJson(diff),
  };
}

final class ComparisonWorktreeRemoved extends _ComparisonAnswer {
  const ComparisonWorktreeRemoved(this.candidateId);

  static const String name = 'comparisons.worktreeRemoved';

  final String candidateId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'candidateId': candidateId};
}

/// Names the winner without claiming anything was merged. Refused for a
/// candidate of another comparison.
final class ComparisonSetWinner extends _ComparisonAnswer {
  const ComparisonSetWinner(this.id, this.candidateId);

  static const String name = 'comparisons.setWinner';

  final String id;
  final String? candidateId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'id': id,
    'candidateId': candidateId,
  };
}

/// Ends a comparison — merged or discarded — at the server's clock.
final class ComparisonClose extends _ComparisonAnswer {
  const ComparisonClose(
    this.id, {
    required this.outcome,
    this.winnerCandidateId,
    this.mergedCommit,
  });

  static const String name = 'comparisons.close';

  final String id;
  final ComparisonOutcome outcome;
  final String? winnerCandidateId;
  final String? mergedCommit;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'id': id,
    'outcome': outcome.name,
    'winnerCandidateId': ?winnerCandidateId,
    'mergedCommit': ?mergedCommit,
  };
}

final class ComparisonArchive extends _ComparisonAnswer {
  const ComparisonArchive(this.id, {required this.archived});

  static const String name = 'comparisons.archive';

  final String id;
  final bool archived;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id, 'archived': archived};
}

sealed class _ComparisonAnswer extends ComparisonsRequest<Comparison> {
  const _ComparisonAnswer();

  @override
  Object? resultToJson(Comparison result) => comparisonToJson(result);

  @override
  Comparison resultFromJson(Object? json) =>
      _decode(kind, () => comparisonFromJson(_object(json, kind)));
}
