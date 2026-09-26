import 'package:agent_cli/process.dart';
import 'package:karmashala_comparisons/comparisons.dart';
import 'package:karmashala_comparisons/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:test/test.dart';

/// The comparisons tables (moved from the app), and the wire shape and rules
/// a client's copy follows.
void main() {
  final t0 = DateTime.utc(2026, 9, 27, 10);
  late AppDatabase db;
  late ComparisonDao dao;

  Comparison comparison(String id, {String repositoryId = 'r1', int? at}) =>
      Comparison(
        id: id,
        repositoryId: repositoryId,
        prompt: 'Make it faster',
        createdAt: t0.add(Duration(minutes: at ?? 0)),
        candidates: [
          for (final i in [0, 1])
            ComparisonCandidate(
              id: '$id-c$i',
              comparisonId: id,
              position: i,
              installationId: 'i$i',
              agentId: 'agent$i',
              launch: CandidateLaunchState.started,
              sessionId: '$id-s$i',
              worktree: const EnvironmentPath(
                environmentId: 'windows',
                path: r'C:\w',
              ),
            ),
        ],
      );

  setUp(() {
    db = AppDatabase.memory()..execute('PRAGMA foreign_keys = OFF;');
    dao = ComparisonDao(db);
  });
  tearDown(() => db.close());

  test('a verdict round-trips with who produced it; none by default', () {
    dao.insert(comparison('f1'));
    expect(dao.getById('f1')!.candidates.first.evidence, isNull);
    dao.updateEvidence(
      'f1-c0',
      const CandidateEvidence(
        verdict: EvidenceVerdict.passed,
        label: '8 tests, 0 failed',
        runId: 'run-1',
      ),
    );
    final unnamed = dao.getById('f1')!.candidates.first;
    expect(unnamed.evidence!.label, '8 tests, 0 failed');
    expect(unnamed.evidenceAttribution, VerdictAttribution.notRecorded);

    dao.updateEvidence(
      'f1-c0',
      const CandidateEvidence(
        verdict: EvidenceVerdict.passed,
        producerSessionId: 'f1-s0',
      ),
    );
    expect(
      dao.getById('f1')!.candidates.first.evidenceAttribution,
      VerdictAttribution.author,
    );
    dao.updateEvidence(
      'f1-c0',
      const CandidateEvidence(
        verdict: EvidenceVerdict.passed,
        producerSessionId: 'someone-else',
      ),
    );
    expect(
      dao.getById('f1')!.candidates.first.evidenceAttribution,
      VerdictAttribution.independent,
    );
  });

  test('a note is kept against a candidate', () {
    dao
      ..insert(comparison('f1'))
      ..updateNotes('f1-c1', 'over-engineered');
    expect(dao.getById('f1')!.candidates.last.notes, 'over-engineered');
    expect(dao.comparisonOfCandidate('f1-c1'), 'f1');
    expect(dao.comparisonOfCandidate('nope'), isNull);
  });

  test('narrowed to one checkout; the copy orders as the store does', () {
    final all = [
      comparison('a', at: 1),
      comparison('b', repositoryId: 'r2', at: 2),
      comparison('c', at: 2),
    ];
    all.forEach(dao.insert);
    expect(dao.getAll(repositoryId: 'r1').map((c) => c.id), ['c', 'a']);
    expect(dao.getAll(repositoryId: 'other'), isEmpty);
    expect(
      ([...all]..sort(compareComparisons)).map((c) => c.id),
      dao.getAll().map((c) => c.id),
    );
  });

  test('a comparison crosses as JSON unchanged', () {
    dao.insert(comparison('f1'));
    dao.updateDiff(
      'f1-c0',
      CandidateDiffStat(
        filesChanged: 1,
        insertions: 2,
        deletions: 3,
        commits: 4,
        capturedAt: t0,
      ),
    );
    final stored = dao.getById('f1')!;
    final back = comparisonFromJson(comparisonToJson(stored));
    expect(sameComparison(back, stored), isTrue);
    expect(back.candidates.first.diff, stored.candidates.first.diff);
    expect(back.candidates.first.worktree, stored.candidates.first.worktree);
    expect(() => comparisonFromJson({'id': 'x'}), throwsFormatException);
  });

  test('candidates must be the comparison\'s own, in distinct places', () {
    expect(comparisonProblem(comparison('f1')), isNull);
    final stray = comparison('f1').copyWith(
      candidates: [
        ...comparison('f1').candidates,
        comparison('f2').candidates.first,
      ],
    );
    expect(comparisonProblem(stray), contains('another comparison'));
  });
}
