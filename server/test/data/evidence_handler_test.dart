import 'dart:convert';

import 'package:agent_cli/process.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_comparisons/comparisons.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:test/test.dart';

/// The record of what agents did, at the server: checkpoints numbered per
/// session, verification runs recorded step by step or whole, comparisons —
/// each rule, and what every other client is told.
void main() {
  late AppDatabase db;
  late DataService service;
  late DataSession app;
  late List<DataChanges> told;
  final now = DateTime.utc(2026, 9, 27, 12);
  const repo = EnvironmentPath(environmentId: 'windows', path: r'C:\src');

  setUp(() {
    db = AppDatabase.memory();
    service = DataService(db, clock: () => now);
    app = service.open((_) {});
    told = [];
    service.open(told.add).handle(const DataSubscribe());
  });
  tearDown(() => db.close());

  Matcher refused(DataRefusalCode code, [String? words]) => throwsA(
    isA<DataRefused>()
        .having((r) => r.code, 'code', code)
        .having((r) => r.message, 'message', contains(words ?? '')),
  );

  List<DataChange> toldChanges() => [for (final b in told) ...b.changes];

  Checkpoint checkpoint(String id, {String session = 's1', int? turn}) =>
      Checkpoint(
        id: id,
        sessionId: session,
        repository: repo,
        sequence: 0,
        treeSha: 'tree-$id',
        commitSha: 'commit-$id',
        parentCommitSha: null,
        headSha: null,
        reason: CheckpointReason.turn,
        createdAt: now,
        turn: turn,
      );

  group('checkpoints', () {
    test('the server numbers each session\'s chain and tells others', () {
      final first = app.handle(CheckpointRecord(checkpoint('c1'))).value;
      final second = app.handle(CheckpointRecord(checkpoint('c2'))).value;
      final other = app
          .handle(CheckpointRecord(checkpoint('c3', session: 's2')))
          .value;
      expect([first.sequence, second.sequence, other.sequence], [1, 2, 1]);
      expect(
        app.handle(const CheckpointsForSession('s1')).value.map((c) => c.id),
        ['c1', 'c2'],
      );
      expect(toldChanges().whereType<CheckpointRecorded>(), hasLength(3));
      expect(
        (toldChanges().first as CheckpointRecorded).checkpoint.sequence,
        1,
      );
    });

    test('a taken id and an empty tree are refused', () {
      app.handle(CheckpointRecord(checkpoint('c1')));
      expect(
        () => app.handle(CheckpointRecord(checkpoint('c1'))),
        refused(DataRefusalCode.invalid, 'taken'),
      );
      final blank = Checkpoint(
        id: 'c9',
        sessionId: 's1',
        repository: repo,
        sequence: 0,
        treeSha: '',
        commitSha: '',
        parentCommitSha: null,
        headSha: null,
        reason: CheckpointReason.turn,
        createdAt: now,
      );
      expect(
        () => app.handle(CheckpointRecord(blank)),
        refused(DataRefusalCode.invalid),
      );
    });

    test('relabel and prune; a prune reaching another session is refused', () {
      app.handle(CheckpointRecord(checkpoint('c1')));
      app.handle(CheckpointRecord(checkpoint('c2')));
      app.handle(CheckpointRecord(checkpoint('x1', session: 's2')));
      expect(
        app.handle(const CheckpointRelabel('c2', 'late')).value.label,
        'late',
      );
      expect(
        () => app.handle(const CheckpointRelabel('nope', 'x')),
        refused(DataRefusalCode.notFound),
      );
      expect(
        () => app.handle(
          const CheckpointsPrune('s1', dropIds: ['x1'], rewritten: {}),
        ),
        refused(DataRefusalCode.invalid, 'not one of'),
      );
      told.clear();
      app.handle(
        const CheckpointsPrune(
          's1',
          dropIds: ['c1'],
          rewritten: {'c2': (commit: 'new', parent: null)},
        ),
      );
      final left = app.handle(const CheckpointsForSession('s1')).value;
      expect(left.single.commitSha, 'new');
      expect(toldChanges().single, isA<CheckpointsPruned>());
    });
  });

  group('verification', () {
    VerificationRun run(String id, {List<VerificationStep> steps = const []}) =>
        VerificationRun(
          id: id,
          title: 'Verify $id',
          target: const VerificationTarget.change(),
          sessionId: 's1',
          startedAt: now,
          artifactDirectory: '/data/verification/$id',
          steps: steps,
        );
    final step = VerificationStep(
      ordinal: 1,
      kind: VerificationStepKind.note,
      summary: 'Looked',
      at: now,
    );

    test('a run recorded step by step, then finished at the server clock', () {
      app.handle(VerificationStart(run('r1')));
      app.handle(VerificationStepAdd('r1', step));
      expect(
        () => app.handle(VerificationStepAdd('r1', step)),
        refused(DataRefusalCode.invalid, 'already has step'),
      );
      final finished = app
          .handle(
            const VerificationFinish('r1', verdict: VerificationVerdict.pass),
          )
          .value;
      expect(finished.finishedAt, now);
      expect(finished.steps.single.summary, 'Looked');
      expect(toldChanges().map((c) => c.runtimeType), [
        VerificationRunChanged,
        VerificationEvidenceAdded,
        VerificationRunChanged,
      ]);
      // Headers only: another client asks for the steps.
      expect(
        jsonEncode([for (final b in told) b.toJson()]),
        isNot(contains('Looked')),
      );
    });

    test('a whole run is one write; headers list every run', () {
      app.handle(VerificationRecord(run('r1', steps: [step])));
      app.handle(VerificationStart(run('r2')));
      expect(
        () => app.handle(VerificationRecord(run('r1'))),
        refused(DataRefusalCode.invalid, 'taken'),
      );
      final headers = app.handle(const VerificationRuns()).value;
      expect(headers.map((r) => r.id), containsAll(['r1', 'r2']));
      expect(headers.every((r) => r.steps.isEmpty), isTrue);
      final recent = app.handle(const VerificationRecent(sessionId: 's1'));
      expect(recent.value.firstWhere((r) => r.id == 'r1').steps, hasLength(1));
    });

    test('attach, delete, and unknown runs', () {
      app.handle(VerificationStart(run('r1')));
      expect(
        app.handle(const VerificationAttach('r1', 's9')).value.sessionId,
        's9',
      );
      app.handle(const VerificationDelete('r1'));
      expect(app.handle(const VerificationGet('r1')).value, isNull);
      expect(toldChanges().last, isA<VerificationRunRemoved>());
      expect(
        () => app.handle(const VerificationDelete('r1')),
        refused(DataRefusalCode.notFound),
      );
    });
  });

  group('comparisons', () {
    late String repositoryId;

    setUp(() {
      app.handle(
        EnvironmentPut(
          ExecutionEnvironment(
            id: 'windows',
            kind: EnvironmentKind.windowsNative,
            name: 'Windows',
            createdAt: now,
          ),
        ),
      );
      final created = app
          .handle(const ProjectCreate(projectName: 'Demo', root: repo))
          .value;
      repositoryId = created.repositories.single.id;
      told.clear();
    });

    Comparison comparison(String id) => Comparison(
      id: id,
      repositoryId: repositoryId,
      prompt: 'Try it',
      createdAt: now,
      candidates: [
        for (final i in [0, 1])
          ComparisonCandidate(
            id: '$id-k$i',
            comparisonId: id,
            position: i,
            installationId: 'i$i',
            agentId: 'agent$i',
            launch: CandidateLaunchState.started,
          ),
      ],
    );

    test('created whole, then each write answers and tells it whole', () {
      app.handle(ComparisonCreate(comparison('f1')));
      final diff = CandidateDiffStat(
        filesChanged: 2,
        insertions: 5,
        deletions: 1,
        capturedAt: now,
      );
      app.handle(ComparisonRecordDiff('f1-k0', diff));
      app.handle(const ComparisonWorktreeRemoved('f1-k1'));
      final closed = app
          .handle(
            const ComparisonClose(
              'f1',
              outcome: ComparisonOutcome.merged,
              winnerCandidateId: 'f1-k0',
              mergedCommit: 'abc',
            ),
          )
          .value;
      expect(closed.finishedAt, now);
      expect(closed.winner!.diff, diff);
      expect(closed.candidates[1].worktreeRemoved, isTrue);
      expect(toldChanges().whereType<ComparisonChanged>(), hasLength(4));
      expect(app.handle(const ComparisonsList()).value.single.id, 'f1');
    });

    test('its rules: a checkout, candidates of its own, a real outcome', () {
      app.handle(ComparisonCreate(comparison('f1')));
      expect(
        () => app.handle(ComparisonCreate(comparison('f1'))),
        refused(DataRefusalCode.invalid, 'taken'),
      );
      expect(
        () => app.handle(const ComparisonSetWinner('f1', 'other')),
        refused(DataRefusalCode.invalid, 'not one of'),
      );
      expect(
        () => app.handle(
          const ComparisonClose('f1', outcome: ComparisonOutcome.pending),
        ),
        refused(DataRefusalCode.invalid),
      );
      expect(
        () => app.handle(
          ComparisonRecordDiff(
            'nope',
            CandidateDiffStat(
              filesChanged: 0,
              insertions: 0,
              deletions: 0,
              capturedAt: now,
            ),
          ),
        ),
        refused(DataRefusalCode.notFound),
      );
    });

    test('a deleted project tells its comparisons gone', () {
      app.handle(ComparisonCreate(comparison('f1')));
      final projectId = app
          .handle(const WorkspaceList())
          .value
          .projects
          .single
          .id;
      told.clear();
      app.handle(ProjectDelete(projectId));
      expect(toldChanges(), contains(isA<ComparisonRemoved>()));
      expect(app.handle(const ComparisonsList()).value, isEmpty);
    });
  });
}
