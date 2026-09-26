part of '../data_change.dart';

// Checkpoints, verification runs and comparisons.

DataChange? _checkpointsChangeFromJson(
  String name,
  Map<String, Object?> json,
) => switch (name) {
  'checkpointRecorded' => CheckpointRecorded(checkpointFromJson(_row(json))),
  'checkpointsPruned' => CheckpointsPruned(json['id']! as String),
  'checkpointSkipChanged' => CheckpointSkipChanged(
    json['id']! as String,
    json['reason'] as String?,
  ),
  'verificationRunChanged' => VerificationRunChanged(
    verificationRunFromJson(_row(json)),
  ),
  'verificationRunRemoved' => VerificationRunRemoved(json['id']! as String),
  'verificationEvidenceAdded' => VerificationEvidenceAdded(
    json['id']! as String,
  ),
  'comparisonChanged' => ComparisonChanged(comparisonFromJson(_row(json))),
  'comparisonRemoved' => ComparisonRemoved(json['id']! as String),
  _ => null,
};

/// A checkpoint, a verification run or a comparison written.
sealed class EvidenceChange extends DataChange {
  const EvidenceChange();
}

/// A checkpoint recorded or relabelled — metadata only.
final class CheckpointRecorded extends EvidenceChange {
  const CheckpointRecorded(this.checkpoint);

  final Checkpoint checkpoint;

  @override
  Map<String, Object?> toJson() => {
    'change': 'checkpointRecorded',
    'row': checkpointToJson(checkpoint),
  };
}

/// Session [sessionId]'s chain was pruned: a copy of it reads it again.
final class CheckpointsPruned extends EvidenceChange {
  const CheckpointsPruned(this.sessionId);

  final String sessionId;

  @override
  Map<String, Object?> toJson() => {
    'change': 'checkpointsPruned',
    'id': sessionId,
  };
}

/// Why session [sessionId] has no automatic checkpoints right now, as the
/// server's recorder found it — or, [reason] null, that it is checkpointing
/// again. Not a row: the recorder keeps it in memory.
final class CheckpointSkipChanged extends EvidenceChange {
  const CheckpointSkipChanged(this.sessionId, this.reason);

  final String sessionId;
  final String? reason;

  @override
  Map<String, Object?> toJson() => {
    'change': 'checkpointSkipChanged',
    'id': sessionId,
    'reason': ?reason,
  };
}

/// A run's header as it now stands: started, finished, recorded or filed.
final class VerificationRunChanged extends EvidenceChange {
  const VerificationRunChanged(this.run);

  final VerificationRun run;

  @override
  Map<String, Object?> toJson() => {
    'change': 'verificationRunChanged',
    'row': verificationRunToJson(verificationHeaderOf(run)),
  };
}

final class VerificationRunRemoved extends EvidenceChange {
  const VerificationRunRemoved(this.id);

  final String id;

  @override
  Map<String, Object?> toJson() => {
    'change': 'verificationRunRemoved',
    'id': id,
  };
}

/// Run [runId] gained a step or an evidence row: a view of it reads again.
final class VerificationEvidenceAdded extends EvidenceChange {
  const VerificationEvidenceAdded(this.runId);

  final String runId;

  @override
  Map<String, Object?> toJson() => {
    'change': 'verificationEvidenceAdded',
    'id': runId,
  };
}

/// A comparison as it now stands, candidates included.
final class ComparisonChanged extends EvidenceChange {
  const ComparisonChanged(this.comparison);

  final Comparison comparison;

  @override
  Map<String, Object?> toJson() => {
    'change': 'comparisonChanged',
    'row': comparisonToJson(comparison),
  };
}

/// A comparison that went with its checkout.
final class ComparisonRemoved extends EvidenceChange {
  const ComparisonRemoved(this.id);

  final String id;

  @override
  Map<String, Object?> toJson() => {'change': 'comparisonRemoved', 'id': id};
}
