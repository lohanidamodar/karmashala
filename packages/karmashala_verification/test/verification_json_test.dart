import 'package:karmashala_store/database.dart';
import 'package:karmashala_verification/store.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:test/test.dart';

void main() {
  final at = DateTime.utc(2026, 9, 27, 9);

  VerificationRun run(String id, {DateTime? startedAt}) => VerificationRun(
    id: id,
    title: 'Verify $id',
    target: const VerificationTarget.device(serial: 'emu', packageName: 'x.y'),
    sessionId: 's1',
    producedBySessionId: kAppVerifierId,
    startedAt: startedAt ?? at,
    finishedAt: at.add(const Duration(minutes: 1)),
    verdict: VerificationVerdict.fail,
    reason: 'It crashed.',
    artifactDirectory: '/data/verification/$id',
    steps: [
      VerificationStep(
        ordinal: 1,
        kind: VerificationStepKind.tap,
        summary: 'Tap OK',
        detail: 'at 3,4',
        ok: false,
        at: at,
      ),
    ],
    artifacts: [
      VerificationArtifact(
        id: '$id:shot.png',
        runId: id,
        kind: VerificationArtifactKind.screenshot,
        label: 'after tap',
        relativePath: 'shot.png',
        byteSize: 12,
        at: at,
        stepOrdinal: 1,
      ),
    ],
  );

  test('a run crosses whole, steps and evidence rows included', () {
    final back = verificationRunFromJson(verificationRunToJson(run('r1')));
    expect(sameVerificationHeader(back, run('r1')), isTrue);
    expect(back.target.packageName, 'x.y');
    expect(back.steps.single.summary, 'Tap OK');
    expect(back.steps.single.ok, isFalse);
    expect(back.artifacts.single.relativePath, 'shot.png');
    expect(back.artifacts.single.stepOrdinal, 1);
    expect(() => verificationRunFromJson({'id': 'x'}), throwsFormatException);
  });

  test('a header is the run without its steps and evidence', () {
    final header = verificationHeaderOf(run('r1'));
    expect(header.steps, isEmpty);
    expect(header.artifacts, isEmpty);
    expect(sameVerificationHeader(header, run('r1')), isTrue);
  });

  test('the copy orders runs as the store lists them', () {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final dao = VerificationDao(db);
    final runs = [
      run('a', startedAt: at),
      run('b', startedAt: at),
      run('c', startedAt: at.add(const Duration(hours: 1))),
    ];
    for (final r in runs) {
      dao.recordWhole(r);
    }
    expect(
      ([...runs]..sort(compareVerificationRuns)).map((r) => r.id),
      dao.listRuns().map((r) => r.id),
    );
    expect(dao.getRun('a')!.steps, hasLength(1));
  });
}
