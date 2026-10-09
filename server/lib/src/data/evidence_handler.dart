import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_checkpoints/store.dart';
import 'package:karmashala_comparisons/comparisons.dart';
import 'package:karmashala_comparisons/store.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_verification/store.dart';
import 'package:karmashala_verification/verification.dart';

/// The record of what agents did, at the server: checkpoints (an index over
/// git objects in the checkout), verification runs (rows over evidence files
/// beside the store) and fan-out comparisons. Only metadata crosses.
class EvidenceHandler {
  EvidenceHandler(AppDatabase db, this._now)
    : checkpoints = CheckpointDao(db),
      verification = VerificationDao(db),
      comparisons = ComparisonDao(db),
      _repositories = RepositoryDao(db);

  final DateTime Function() _now;
  final CheckpointDao checkpoints;
  final VerificationDao verification;
  final ComparisonDao comparisons;
  final RepositoryDao _repositories;

  Object? handleCheckpoints(
    CheckpointsRequest<Object?> request,
    List<DataChange> changes,
  ) => switch (request) {
    CheckpointsForSession(:final sessionId) => checkpoints.forSession(
      sessionId,
    ),
    CheckpointGet(:final id) => checkpoints.getById(id),
    CheckpointsRecent(:final limit) => checkpoints.recent(limit: limit),
    CheckpointRecord(:final checkpoint) => _record(checkpoint, changes),
    CheckpointRelabel(:final id, :final label) => _relabel(id, label, changes),
    final CheckpointsPrune r => _prune(r, changes),
  };

  Object? handleVerification(
    VerificationRequest<Object?> request,
    List<DataChange> changes,
  ) => switch (request) {
    VerificationRuns() => verification.headers(),
    VerificationRecent(:final limit, :final sessionId) => [
      for (final run in verification.listRuns(
        limit: limit,
        sessionId: sessionId,
      ))
        run.copyWith(
          steps: verification.stepsFor(run.id),
          artifacts: verification.artifactsFor(run.id),
        ),
    ],
    VerificationGet(:final id) => verification.getRun(id),
    VerificationMatching(:final prefix) => verification.findByPrefix(prefix),
    VerificationStart(:final run) => _start(run, changes),
    VerificationStepAdd(:final runId, :final step) => _step(
      runId,
      step,
      changes,
    ),
    VerificationArtifactAdd(:final artifact) => _artifact(artifact, changes),
    final VerificationFinish r => _finish(r, changes),
    VerificationRecord(:final run) => _recordRun(run, changes),
    VerificationAttach(:final id, :final sessionId) => _attach(
      id,
      sessionId,
      changes,
    ),
    VerificationDelete(:final id) => _deleteRun(id, changes),
  };

  Object? handleComparisons(
    ComparisonsRequest<Object?> request,
    List<DataChange> changes,
  ) => switch (request) {
    ComparisonsList() => comparisons.getAll(includeArchived: true),
    ComparisonCreate(:final comparison) => _create(comparison, changes),
    ComparisonRecordDiff(:final candidateId, :final diff) => _candidate(
      candidateId,
      changes,
      (dao) => dao.updateDiff(candidateId, diff),
    ),
    ComparisonWorktreeRemoved(:final candidateId) => _candidate(
      candidateId,
      changes,
      (dao) => dao.markWorktreeRemoved(candidateId),
    ),
    ComparisonSetWinner(:final id, :final candidateId) => _winner(
      id,
      candidateId,
      changes,
    ),
    final ComparisonClose r => _close(r, changes),
    ComparisonArchive(:final id, :final archived) => _changed(
      _comparison(id).id,
      changes,
      () => comparisons.setArchived(id, archived),
    ),
  };

  /// What deleting checkouts takes with it here (their comparisons, by the
  /// schema's cascade), read before the delete and told after it.
  List<DataChange> Function() checkoutsGoing(List<String> checkoutIds) {
    final going = [
      for (final id in checkoutIds)
        for (final c in comparisons.getAll(
          repositoryId: id,
          includeArchived: true,
        ))
          c.id,
    ];
    return () => [for (final id in going) ComparisonRemoved(id)];
  }

  // Checkpoints.

  Checkpoint _record(Checkpoint checkpoint, List<DataChange> changes) {
    if (checkpoint.id.trim().isEmpty || checkpoint.sessionId.trim().isEmpty) {
      throw const DataRefused.invalid('a checkpoint needs an id and a session');
    }
    if (checkpoint.treeSha.isEmpty || checkpoint.commitSha.isEmpty) {
      throw const DataRefused.invalid('a checkpoint names its tree and commit');
    }
    if (checkpoints.getById(checkpoint.id) != null) {
      throw DataRefused.invalid('checkpoint id ${checkpoint.id} is taken');
    }
    final stored = checkpoints.insert(checkpoint);
    changes.add(CheckpointRecorded(stored));
    return stored;
  }

  Checkpoint _relabel(String id, String label, List<DataChange> changes) {
    if (checkpoints.getById(id) == null) {
      throw DataRefused.notFound('no checkpoint with id $id');
    }
    checkpoints.relabel(id, label);
    final stored = checkpoints.getById(id)!;
    changes.add(CheckpointRecorded(stored));
    return stored;
  }

  DataAck _prune(CheckpointsPrune r, List<DataChange> changes) {
    final own = {for (final c in checkpoints.forSession(r.sessionId)) c.id};
    for (final id in [...r.dropIds, ...r.rewritten.keys]) {
      if (!own.contains(id)) {
        throw DataRefused.invalid(
          'checkpoint $id is not one of session ${r.sessionId}\'s',
        );
      }
    }
    checkpoints.prune(dropIds: r.dropIds, rewritten: r.rewritten);
    changes.add(CheckpointsPruned(r.sessionId));
    return const DataAck();
  }

  // Verification runs.

  VerificationRun _existingRun(String id) =>
      verification.getRun(id) ??
      (throw DataRefused.notFound('no verification run with id $id'));

  void _freshRun(VerificationRun run) {
    if (run.id.trim().isEmpty || run.title.trim().isEmpty) {
      throw const DataRefused.invalid('a run needs an id and a title');
    }
    if (verification.getRun(run.id) != null) {
      throw DataRefused.invalid('verification run id ${run.id} is taken');
    }
  }

  VerificationRun _start(VerificationRun run, List<DataChange> changes) {
    _freshRun(run);
    verification.insertRun(verificationHeaderOf(run));
    final stored = _existingRun(run.id);
    changes.add(VerificationRunChanged(stored));
    return stored;
  }

  DataAck _step(String runId, VerificationStep step, List<DataChange> changes) {
    final run = _existingRun(runId);
    if (run.steps.any((s) => s.ordinal == step.ordinal)) {
      throw DataRefused.invalid('run $runId already has step ${step.ordinal}');
    }
    verification.insertStep(runId, step);
    changes.add(VerificationEvidenceAdded(runId));
    return const DataAck();
  }

  DataAck _artifact(VerificationArtifact artifact, List<DataChange> changes) {
    _existingRun(artifact.runId);
    verification.insertArtifact(artifact);
    changes.add(VerificationEvidenceAdded(artifact.runId));
    return const DataAck();
  }

  VerificationRun _finish(VerificationFinish r, List<DataChange> changes) {
    _existingRun(r.id);
    verification.finishRun(
      r.id,
      finishedAt: _now(),
      verdict: r.verdict,
      reason: r.reason,
      producedBySessionId: r.producedBySessionId,
      identity: r.identity,
    );
    final stored = _existingRun(r.id);
    changes.add(VerificationRunChanged(stored));
    return stored;
  }

  VerificationRun _recordRun(VerificationRun run, List<DataChange> changes) {
    _freshRun(run);
    final stored = verification.recordWhole(run);
    changes.add(VerificationRunChanged(stored));
    return stored;
  }

  VerificationRun _attach(
    String id,
    String? sessionId,
    List<DataChange> changes,
  ) {
    _existingRun(id);
    verification.updateSessionId(id, sessionId);
    final stored = _existingRun(id);
    changes.add(VerificationRunChanged(stored));
    return stored;
  }

  DataAck _deleteRun(String id, List<DataChange> changes) {
    _existingRun(id);
    verification.deleteRun(id);
    changes.add(VerificationRunRemoved(id));
    return const DataAck();
  }

  // Comparisons.

  Comparison _comparison(String id) =>
      comparisons.getById(id) ??
      (throw DataRefused.notFound('no comparison with id $id'));

  Comparison _changed(
    String id,
    List<DataChange> changes,
    void Function() write,
  ) {
    write();
    final stored = _comparison(id);
    changes.add(ComparisonChanged(stored));
    return stored;
  }

  Comparison _create(Comparison comparison, List<DataChange> changes) {
    final problem = comparisonProblem(comparison);
    if (problem != null) throw DataRefused.invalid(problem);
    if (comparisons.getById(comparison.id) != null) {
      throw DataRefused.invalid('comparison id ${comparison.id} is taken');
    }
    if (_repositories.getById(comparison.repositoryId) == null) {
      throw DataRefused.notFound(
        'no checkout with id ${comparison.repositoryId}',
      );
    }
    for (final candidate in comparison.candidates) {
      if (comparisons.comparisonOfCandidate(candidate.id) != null) {
        throw DataRefused.invalid('candidate id ${candidate.id} is taken');
      }
    }
    return _changed(
      comparison.id,
      changes,
      () => comparisons.insert(comparison),
    );
  }

  Comparison _candidate(
    String candidateId,
    List<DataChange> changes,
    void Function(ComparisonDao dao) write,
  ) {
    final id =
        comparisons.comparisonOfCandidate(candidateId) ??
        (throw DataRefused.notFound('no candidate with id $candidateId'));
    return _changed(id, changes, () => write(comparisons));
  }

  void _checkCandidate(Comparison comparison, String? candidateId) {
    if (candidateId == null) return;
    if (!comparison.candidates.any((c) => c.id == candidateId)) {
      throw DataRefused.invalid(
        'candidate $candidateId is not one of comparison ${comparison.id}\'s',
      );
    }
  }

  Comparison _winner(String id, String? candidateId, List<DataChange> changes) {
    _checkCandidate(_comparison(id), candidateId);
    return _changed(
      id,
      changes,
      () => comparisons.updateWinner(id, candidateId),
    );
  }

  Comparison _close(ComparisonClose r, List<DataChange> changes) {
    if (r.outcome == ComparisonOutcome.pending) {
      throw const DataRefused.invalid(
        'a comparison closes merged or discarded',
      );
    }
    _checkCandidate(_comparison(r.id), r.winnerCandidateId);
    return _changed(
      r.id,
      changes,
      () => comparisons.updateOutcome(
        r.id,
        outcome: r.outcome,
        winnerCandidateId: r.winnerCandidateId,
        mergedCommit: r.mergedCommit,
        finishedAt: _now(),
      ),
    );
  }
}
