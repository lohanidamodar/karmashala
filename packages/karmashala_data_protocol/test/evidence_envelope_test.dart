import 'dart:convert';

import 'package:agent_cli/process.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_comparisons/comparisons.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:test/test.dart';

/// Checkpoints, verification runs and comparisons through the envelope as
/// JSON text: metadata only — no file contents cross.
void main() {
  final t0 = DateTime.utc(2026, 9, 27, 9);
  final checkpoint = Checkpoint(
    id: 'c1',
    sessionId: 's1',
    repository: const EnvironmentPath(environmentId: 'windows', path: r'C:\r'),
    sequence: 3,
    treeSha: 'tree',
    commitSha: 'commit',
    parentCommitSha: 'parent',
    headSha: 'head',
    reason: CheckpointReason.turnStart,
    createdAt: t0,
    turn: 2,
    prompt: 'Fix it',
    files: const [
      FileChange(
        path: 'a.dart',
        type: FileChangeType.added,
        staged: false,
        unstaged: true,
      ),
    ],
    lineStats: const {'a.dart': FileDiffStat(added: 4, removed: 0)},
  );
  final step = VerificationStep(
    ordinal: 1,
    kind: VerificationStepKind.click,
    summary: 'Click Save',
    at: t0,
  );
  final artifact = VerificationArtifact(
    id: 'r1:shot.png',
    runId: 'r1',
    kind: VerificationArtifactKind.screenshot,
    label: 'saved',
    relativePath: 'shot.png',
    byteSize: 10,
    at: t0,
    stepOrdinal: 1,
  );
  final run = VerificationRun(
    id: 'r1',
    title: 'Verify save',
    target: const VerificationTarget.browser('http://localhost'),
    sessionId: 's1',
    startedAt: t0,
    artifactDirectory: '/data/verification/r1',
    steps: [step],
    artifacts: [artifact],
  );
  final comparison = Comparison(
    id: 'f1',
    repositoryId: 'repo',
    prompt: 'Try it',
    createdAt: t0,
    candidates: [
      ComparisonCandidate(
        id: 'k1',
        comparisonId: 'f1',
        position: 0,
        installationId: 'i1',
        agentId: 'codex',
        launch: CandidateLaunchState.started,
        sessionId: 's2',
        worktree: const EnvironmentPath(environmentId: 'windows', path: 'w'),
        diff: CandidateDiffStat(
          filesChanged: 1,
          insertions: 2,
          deletions: 3,
          capturedAt: t0,
        ),
        evidence: const CandidateEvidence(
          verdict: EvidenceVerdict.passed,
          runId: 'r1',
        ),
      ),
    ],
  );

  Map<String, Object?> overTheWire(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  test('every request round-trips with its arguments', () {
    final requests = <DataRequest<Object?>>[
      const CheckpointsForSession('s1'),
      const CheckpointGet('c1'),
      const CheckpointsRecent(5),
      CheckpointRecord(checkpoint),
      const CheckpointRelabel('c1', 'kept'),
      const CheckpointsPrune(
        's1',
        dropIds: ['c0'],
        rewritten: {'c1': (commit: 'n1', parent: null)},
      ),
      const VerificationRuns(),
      const VerificationRecent(limit: 5, sessionId: 's1'),
      const VerificationGet('r1'),
      const VerificationMatching('r'),
      VerificationStart(run),
      VerificationStepAdd('r1', step),
      VerificationArtifactAdd(artifact),
      const VerificationFinish(
        'r1',
        verdict: VerificationVerdict.pass,
        reason: 'works',
        producedBySessionId: 's9',
      ),
      VerificationRecord(run),
      const VerificationAttach('r1', null),
      const VerificationDelete('r1'),
      const ComparisonsList(),
      ComparisonCreate(comparison),
      ComparisonRecordDiff('k1', comparison.candidates.single.diff!),
      const ComparisonWorktreeRemoved('k1'),
      const ComparisonSetWinner('f1', 'k1'),
      const ComparisonClose(
        'f1',
        outcome: ComparisonOutcome.merged,
        winnerCandidateId: 'k1',
        mergedCommit: 'abc',
      ),
      const ComparisonArchive('f1', archived: true),
    ];
    for (final request in requests) {
      final read = DataEnvelope.readRequest(
        overTheWire(DataEnvelope.request(3, request)),
      );
      expect(read.refusal, isNull, reason: request.kind);
      expect(read.request!.kind, request.kind);
      expect(
        read.request!.argumentsToJson(),
        request.argumentsToJson(),
        reason: request.kind,
      );
    }
  });

  test('a start sends the header only; a record sends the run whole', () {
    final start = DataEnvelope.request(1, VerificationStart(run));
    expect(jsonEncode(start), isNot(contains('Click Save')));
    final record = DataEnvelope.request(1, VerificationRecord(run));
    expect(jsonEncode(record), contains('Click Save'));
  });

  test('answers carry typed results', () {
    DataReply<R> roundTrip<R>(DataRequest<R> request, R result) =>
        DataEnvelope.readAnswer(
          overTheWire(
            DataEnvelope.answer(4, request, DataReply(result, 9, const [])),
          ),
          request,
        );
    final recorded = roundTrip(CheckpointRecord(checkpoint), checkpoint).value;
    expect(recorded.sequence, 3);
    expect(recorded.additions, 4);
    expect(roundTrip(const CheckpointGet('x'), null).value, isNull);
    final got = roundTrip(const VerificationGet('r1'), run).value!;
    expect(got.artifacts.single.relativePath, 'shot.png');
    final list = roundTrip(const ComparisonsList(), [comparison]).value;
    expect(list.single.candidates.single.evidence!.runId, 'r1');
  });

  test('changes round-trip; a run is told by its header', () {
    final batch = DataChanges(7, [
      CheckpointRecorded(checkpoint),
      const CheckpointsPruned('s1'),
      VerificationRunChanged(run),
      const VerificationRunRemoved('r0'),
      const VerificationEvidenceAdded('r1'),
      ComparisonChanged(comparison),
      const ComparisonRemoved('f0'),
    ]);
    final text = jsonEncode(DataEnvelope.changes(batch));
    expect(text, isNot(contains('Click Save')));
    final back = DataEnvelope.readChanges(
      (jsonDecode(text) as Map).cast<String, Object?>(),
    );
    expect(back.changes.map((c) => c.runtimeType), [
      CheckpointRecorded,
      CheckpointsPruned,
      VerificationRunChanged,
      VerificationRunRemoved,
      VerificationEvidenceAdded,
      ComparisonChanged,
      ComparisonRemoved,
    ]);
    expect((back.changes[0] as CheckpointRecorded).checkpoint.turn, 2);
    expect((back.changes[2] as VerificationRunChanged).run.steps, isEmpty);
  });

  test('a finish naming no verdict is refused', () {
    final read = DataEnvelope.readRequest({
      'id': 1,
      'kind': VerificationFinish.name,
      'arguments': {'id': 'r1', 'verdict': 'maybe'},
    });
    expect(read.refusal?.code, DataRefusalCode.invalid);
  });
}
