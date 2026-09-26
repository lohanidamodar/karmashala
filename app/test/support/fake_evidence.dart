part of 'fake_data_server.dart';

/// The checkpoint index of a [FakeDataServer], shaped like the server's DAO:
/// numbered per session, read per session.
class FakeCheckpointRows {
  FakeCheckpointRows._(this._server);

  final FakeDataServer _server;
  final _rows = <String, Checkpoint>{};

  Checkpoint? getById(String id) => _rows[id];

  /// [sessionId]'s checkpoints, oldest first.
  List<Checkpoint> forSession(String sessionId) => [
    for (final c in _rows.values)
      if (c.sessionId == sessionId) c,
  ]..sort((a, b) => a.sequence.compareTo(b.sequence));

  /// [sessionId]'s checkpoints of [repository], oldest first.
  List<Checkpoint> forRepository(
    String sessionId,
    EnvironmentPath repository,
  ) => checkpointChainIn(forSession(sessionId), repository);

  List<Checkpoint> getAll() => [..._rows.values];

  /// Records [checkpoint] as the server would — numbered in its session.
  Checkpoint insert(Checkpoint checkpoint) {
    final stored = _insert(checkpoint);
    _server._tell(null, [CheckpointRecorded(stored)]);
    return stored;
  }

  Checkpoint _insert(Checkpoint checkpoint) =>
      _rows[checkpoint.id] = checkpoint.copyWith(
        sequence: nextCheckpointSequence(forSession(checkpoint.sessionId)),
        // In path order, as the DAO reads them.
        files: [...checkpoint.files]..sort((a, b) => a.path.compareTo(b.path)),
      );

  Object? _handle(CheckpointsRequest<Object?> r, List<DataChange> changes) {
    switch (r) {
      case CheckpointsForSession(:final sessionId):
        return forSession(sessionId);
      case CheckpointGet(:final id):
        return _rows[id];
      case CheckpointsRecent(:final limit):
        return (getAll()..sort((a, b) => b.createdAt.compareTo(a.createdAt)))
            .take(limit)
            .toList();
      case CheckpointRecord(:final checkpoint):
        if (_rows.containsKey(checkpoint.id)) {
          throw DataRefused.invalid('checkpoint id ${checkpoint.id} is taken');
        }
        final stored = _insert(checkpoint);
        changes.add(CheckpointRecorded(stored));
        return stored;
      case CheckpointRelabel(:final id, :final label):
        final stored = _rows[id] = _checkpoint(id).copyWith(label: label);
        changes.add(CheckpointRecorded(stored));
        return stored;
      case CheckpointsPrune(:final sessionId, :final dropIds, :final rewritten):
        dropIds.forEach(_rows.remove);
        rewritten.forEach((id, commits) {
          _rows[id] = _checkpoint(id).copyWith(commits: commits);
        });
        changes.add(CheckpointsPruned(sessionId));
        return const DataAck();
    }
  }

  Checkpoint _checkpoint(String id) =>
      _rows[id] ?? (throw DataRefused.notFound('no checkpoint with id $id'));
}

/// The checkpoint work of a [FakeDataServer] — what the server's recorder
/// does in git — scripted: every request is kept in [asked], a capture
/// records [nextCapture] (null: nothing moved), a diff answers [diffs], a
/// restore answers [restoreWith], and skip reasons are [setSkip].
class FakeCheckpointWork {
  FakeCheckpointWork._(this._server);

  final FakeDataServer _server;

  /// Every checkpoint work request, in the order asked.
  final asked = <CheckpointWorkRequest<Object?>>[];

  /// What the next capture (or run base) records; null answers "nothing
  /// moved".
  Checkpoint? nextCapture;

  /// Checkpoint id → the diff the server reads from git.
  final diffs = <String, String>{};

  /// How a restore is answered; by default it restores every file the
  /// checkpoint names (or only the paths asked for).
  CheckpointRestoreAnswer Function(CheckpointRestore request, Checkpoint c)?
  restoreWith;

  final _skips = <String, String>{};

  /// Says why [sessionId] has no automatic checkpoints (null: it has again),
  /// told to every client as the recorder would.
  void setSkip(String sessionId, String? reason) {
    reason == null ? _skips.remove(sessionId) : _skips[sessionId] = reason;
    _server._tell(null, [CheckpointSkipChanged(sessionId, reason)]);
  }

  Object? _handle(CheckpointWorkRequest<Object?> r) {
    asked.add(r);
    switch (r) {
      case CheckpointCapture() || CheckpointCaptureBase():
        final next = nextCapture;
        nextCapture = null;
        return next == null ? null : _server.checkpointRows.insert(next);
      case CheckpointDiff(:final id):
        _server.checkpointRows._checkpoint(id);
        return diffs[id] ?? '';
      case final CheckpointRestore r:
        final checkpoint = _server.checkpointRows._checkpoint(r.id);
        final answer = restoreWith;
        if (answer != null) return answer(r, checkpoint);
        return CheckpointRestoreAnswer.restored(
          RestoreOutcome(
            restored: checkpoint,
            safetyCheckpoint: null,
            files: [
              for (final file in checkpoint.files)
                if (r.paths.isEmpty || r.paths.contains(file.path)) file,
            ],
            alreadyThere: false,
          ),
        );
      case CheckpointSkips():
        return Map.of(_skips);
    }
  }
}

/// The verification runs of a [FakeDataServer], kept whole; a client is
/// told their headers.
class FakeVerificationRows {
  FakeVerificationRows._(this._server);

  final FakeDataServer _server;
  final _rows = <String, VerificationRun>{};

  VerificationRun? getRun(String id) => _rows[id];

  /// Runs newest first, whole; of [sessionId] when given.
  List<VerificationRun> listRuns({String? sessionId}) => [
    for (final run in _rows.values)
      if (sessionId == null || run.sessionId == sessionId) run,
  ]..sort(compareVerificationRuns);

  /// A run recorded as the server would — seeded, or another client's.
  void put(VerificationRun run) {
    _rows[run.id] = run;
    _server._tell(null, [VerificationRunChanged(run)]);
  }

  /// [put], in the server DAO's words.
  void insertRun(VerificationRun run) => put(run);

  /// Closes run [id]; a null [verdict] is a word this build cannot read.
  void finishRun(
    String id, {
    required DateTime finishedAt,
    VerificationVerdict? verdict,
    String? reason,
    String? producedBySessionId,
  }) {
    final run = _run(id);
    put(
      VerificationRun(
        id: run.id,
        title: run.title,
        target: run.target,
        startedAt: run.startedAt,
        artifactDirectory: run.artifactDirectory,
        sessionId: run.sessionId,
        producedBySessionId: producedBySessionId ?? run.producedBySessionId,
        finishedAt: finishedAt,
        verdict: verdict,
        reason: reason,
        steps: run.steps,
        artifacts: run.artifacts,
      ),
    );
  }

  Object? _handle(VerificationRequest<Object?> r, List<DataChange> changes) {
    switch (r) {
      case VerificationRuns():
        return [for (final run in listRuns()) verificationHeaderOf(run)];
      case VerificationRecent(:final limit, :final sessionId):
        return listRuns(sessionId: sessionId).take(limit).toList();
      case VerificationGet(:final id):
        return _rows[id];
      case VerificationMatching(:final prefix):
        return [
          for (final run in listRuns())
            if (prefix.trim().isNotEmpty && run.id.startsWith(prefix))
              verificationHeaderOf(run),
        ];
      case VerificationStart(:final run):
        return _fresh(verificationHeaderOf(run), changes);
      case VerificationRecord(:final run):
        return _fresh(run, changes);
      case VerificationStepAdd(:final runId, :final step):
        final run = _run(runId);
        _rows[runId] = run.copyWith(steps: [...run.steps, step]);
        changes.add(VerificationEvidenceAdded(runId));
        return const DataAck();
      case VerificationArtifactAdd(:final artifact):
        final run = _run(artifact.runId);
        _rows[run.id] = run.copyWith(artifacts: [...run.artifacts, artifact]);
        changes.add(VerificationEvidenceAdded(run.id));
        return const DataAck();
      case VerificationFinish(
        :final id,
        :final verdict,
        :final reason,
        :final producedBySessionId,
      ):
        final run = _run(id);
        return _changed(
          VerificationRun(
            id: run.id,
            title: run.title,
            target: run.target,
            startedAt: run.startedAt,
            artifactDirectory: run.artifactDirectory,
            sessionId: run.sessionId,
            producedBySessionId: producedBySessionId ?? run.producedBySessionId,
            finishedAt: _server._now(),
            verdict: verdict,
            reason: reason,
            steps: run.steps,
            artifacts: run.artifacts,
          ),
          changes,
        );
      case VerificationAttach(:final id, :final sessionId):
        final run = _run(id);
        return _changed(
          VerificationRun(
            id: run.id,
            title: run.title,
            target: run.target,
            startedAt: run.startedAt,
            artifactDirectory: run.artifactDirectory,
            sessionId: sessionId,
            producedBySessionId: run.producedBySessionId,
            finishedAt: run.finishedAt,
            verdict: run.verdict,
            reason: run.reason,
            steps: run.steps,
            artifacts: run.artifacts,
          ),
          changes,
        );
      case VerificationDelete(:final id):
        _run(id);
        _rows.remove(id);
        changes.add(VerificationRunRemoved(id));
        return const DataAck();
    }
  }

  VerificationRun _run(String id) =>
      _rows[id] ?? (throw DataRefused.notFound('no verification run $id'));

  VerificationRun _fresh(VerificationRun run, List<DataChange> changes) {
    if (_rows.containsKey(run.id)) {
      throw DataRefused.invalid('verification run id ${run.id} is taken');
    }
    return _changed(run, changes);
  }

  VerificationRun _changed(VerificationRun run, List<DataChange> changes) {
    _rows[run.id] = run;
    changes.add(VerificationRunChanged(run));
    return run;
  }
}

/// The fan-out comparisons of a [FakeDataServer], kept whole.
class FakeComparisonRows {
  FakeComparisonRows._(this._server);

  final FakeDataServer _server;
  final _rows = <String, Comparison>{};

  Comparison? getById(String id) => _rows[id];

  /// Newest first, archived ones too.
  List<Comparison> getAll() => [..._rows.values]..sort(compareComparisons);

  /// A comparison as the server would keep it — seeded, or another client's.
  void insert(Comparison comparison) {
    _rows[comparison.id] = comparison;
    _server._tell(null, [ComparisonChanged(comparison)]);
  }

  /// Attaches (or clears) a candidate's verdict, as the server's DAO does.
  void updateEvidence(String candidateId, CandidateEvidence? evidence) {
    final changes = <DataChange>[];
    _candidate(
      candidateId,
      changes,
      (c) => ComparisonCandidate(
        id: c.id,
        comparisonId: c.comparisonId,
        position: c.position,
        installationId: c.installationId,
        agentId: c.agentId,
        launch: c.launch,
        sessionId: c.sessionId,
        worktree: c.worktree,
        branch: c.branch,
        failure: c.failure,
        diff: c.diff,
        worktreeRemoved: c.worktreeRemoved,
        evidence: evidence,
        notes: c.notes,
      ),
    );
    _server._tell(null, changes);
  }

  /// A candidate as stored, or null.
  ComparisonCandidate? candidate(String candidateId) {
    for (final comparison in _rows.values) {
      for (final c in comparison.candidates) {
        if (c.id == candidateId) return c;
      }
    }
    return null;
  }

  Object? _handle(ComparisonsRequest<Object?> r, List<DataChange> changes) {
    switch (r) {
      case ComparisonsList():
        return getAll();
      case ComparisonCreate(:final comparison):
        final problem = comparisonProblem(comparison);
        if (problem != null) throw DataRefused.invalid(problem);
        if (_rows.containsKey(comparison.id)) {
          throw DataRefused.invalid('comparison ${comparison.id} is taken');
        }
        return _changed(comparison, changes);
      case ComparisonRecordDiff(:final candidateId, :final diff):
        return _candidate(candidateId, changes, (c) => c.copyWith(diff: diff));
      case ComparisonWorktreeRemoved(:final candidateId):
        return _candidate(
          candidateId,
          changes,
          (c) => c.copyWith(worktreeRemoved: true),
        );
      case ComparisonSetWinner(:final id, :final candidateId):
        final comparison = _comparison(id);
        return _changed(
          Comparison(
            id: comparison.id,
            repositoryId: comparison.repositoryId,
            prompt: comparison.prompt,
            createdAt: comparison.createdAt,
            candidates: comparison.candidates,
            finishedAt: comparison.finishedAt,
            outcome: comparison.outcome,
            winnerCandidateId: candidateId,
            mergedCommit: comparison.mergedCommit,
            archived: comparison.archived,
          ),
          changes,
        );
      case ComparisonClose(
        :final id,
        :final outcome,
        :final winnerCandidateId,
        :final mergedCommit,
      ):
        final comparison = _comparison(id);
        return _changed(
          Comparison(
            id: comparison.id,
            repositoryId: comparison.repositoryId,
            prompt: comparison.prompt,
            createdAt: comparison.createdAt,
            candidates: comparison.candidates,
            finishedAt: _server._now(),
            outcome: outcome,
            winnerCandidateId: winnerCandidateId,
            mergedCommit: mergedCommit,
            archived: comparison.archived,
          ),
          changes,
        );
      case ComparisonArchive(:final id, :final archived):
        return _changed(_comparison(id).copyWith(archived: archived), changes);
    }
  }

  Comparison _comparison(String id) =>
      _rows[id] ?? (throw DataRefused.notFound('no comparison with id $id'));

  Comparison _candidate(
    String candidateId,
    List<DataChange> changes,
    ComparisonCandidate Function(ComparisonCandidate candidate) edit,
  ) {
    for (final comparison in _rows.values) {
      if (comparison.candidates.any((c) => c.id == candidateId)) {
        return _changed(
          comparison.copyWith(
            candidates: [
              for (final c in comparison.candidates)
                c.id == candidateId ? edit(c) : c,
            ],
          ),
          changes,
        );
      }
    }
    throw DataRefused.notFound('no candidate with id $candidateId');
  }

  Comparison _changed(Comparison comparison, List<DataChange> changes) {
    _rows[comparison.id] = comparison;
    changes.add(ComparisonChanged(comparison));
    return comparison;
  }
}

extension on FakeDataServer {
  void _applyEvidence(EvidenceChange change) {
    switch (change) {
      case CheckpointRecorded(:final checkpoint):
        checkpointRows._rows[checkpoint.id] = checkpoint;
      case VerificationRunChanged(:final run):
        verificationRows._rows[run.id] = run;
      case VerificationRunRemoved(:final id):
        verificationRows._rows.remove(id);
      case ComparisonChanged(:final comparison):
        comparisonRows._rows[comparison.id] = comparison;
      case ComparisonRemoved(:final id):
        comparisonRows._rows.remove(id);
      case CheckpointsPruned() ||
          CheckpointSkipChanged() ||
          VerificationEvidenceAdded():
        break;
    }
  }
}
