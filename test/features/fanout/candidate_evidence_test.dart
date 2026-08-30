import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/features/fanout/application/comparison_providers.dart';
import 'package:chitragupta/src/features/fanout/domain/comparison.dart';
import 'package:chitragupta/src/features/verification/data/verification_dao.dart';
import 'package:chitragupta/src/features/verification/domain/verification_run.dart';
import 'package:chitragupta/src/features/verification/domain/verification_target.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fan-out's verdict column reads the verification feature's runs.
///
/// Until Loop 68 `candidateEvidenceProvider` was a stub returning `null` for
/// every session, so a comparison could only ever show the copy frozen into its
/// own row — a run that passed after the comparison was made never appeared.
void main() {
  late AppDatabase db;
  late VerificationDao dao;

  setUp(() {
    db = AppDatabase.memory();
    dao = VerificationDao(db);
  });
  tearDown(() => db.close());

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(c.dispose);
    return c;
  }

  VerificationRun run(
    String id, {
    required String? sessionId,
    required DateTime startedAt,
  }) => VerificationRun(
    id: id,
    title: 'Run $id',
    target: const VerificationTarget.browser('http://localhost:3000'),
    sessionId: sessionId,
    startedAt: startedAt,
    artifactDirectory: r'C:\runs\$id',
  );

  CandidateEvidence? lookup(String sessionId) =>
      container().read(candidateEvidenceProvider)(sessionId);

  test('answers with the newest run that reached a verdict', () {
    dao.insertRun(
      run('r1', sessionId: 's1', startedAt: DateTime.utc(2026, 1, 1)),
    );
    dao.finishRun(
      'r1',
      finishedAt: DateTime.utc(2026, 1, 1, 1),
      verdict: VerificationVerdict.fail,
      reason: 'two console errors',
    );
    dao.insertRun(
      run('r2', sessionId: 's1', startedAt: DateTime.utc(2026, 1, 2)),
    );
    dao.finishRun(
      'r2',
      finishedAt: DateTime.utc(2026, 1, 2, 1),
      verdict: VerificationVerdict.pass,
      reason: 'the flow completes',
    );

    final evidence = lookup('s1');

    expect(evidence, isNotNull);
    expect(evidence!.verdict, EvidenceVerdict.passed);
    expect(evidence.label, 'the flow completes');
    expect(evidence.runId, 'r2');
  });

  test('an open run is not evidence yet — the last verdict still stands', () {
    dao.insertRun(
      run('r1', sessionId: 's1', startedAt: DateTime.utc(2026, 1, 1)),
    );
    dao.finishRun(
      'r1',
      finishedAt: DateTime.utc(2026, 1, 1, 1),
      verdict: VerificationVerdict.inconclusive,
    );
    // Started later, never finished.
    dao.insertRun(
      run('r2', sessionId: 's1', startedAt: DateTime.utc(2026, 1, 3)),
    );

    final evidence = lookup('s1');

    expect(evidence!.runId, 'r1');
    expect(evidence.verdict, EvidenceVerdict.inconclusive);
    // No reason was given, so the run's title is what the chip says.
    expect(evidence.label, 'Run r1');
  });

  test('another session\'s run is not this candidate\'s evidence', () {
    dao.insertRun(
      run('r1', sessionId: 's1', startedAt: DateTime.utc(2026, 1, 1)),
    );
    dao.finishRun(
      'r1',
      finishedAt: DateTime.utc(2026, 1, 1, 1),
      verdict: VerificationVerdict.pass,
    );
    dao.insertRun(run('r2', sessionId: null, startedAt: DateTime.utc(2026, 1)));
    dao.finishRun(
      'r2',
      finishedAt: DateTime.utc(2026, 1, 1, 2),
      verdict: VerificationVerdict.fail,
    );

    expect(lookup('s2'), isNull);
  });
}
