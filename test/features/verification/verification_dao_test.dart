import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/verification/data/verification_dao.dart';
import 'package:chitragupta/src/features/verification/domain/verification_artifact.dart';
import 'package:chitragupta/src/features/verification/domain/verification_run.dart';
import 'package:chitragupta/src/features/verification/domain/verification_step.dart';
import 'package:chitragupta/src/features/verification/domain/verification_target.dart';
import 'package:flutter_test/flutter_test.dart';

final _t0 = DateTime.utc(2026, 8, 30, 12);

VerificationRun _run(
  String id, {
  VerificationTarget? target,
  String? sessionId,
  DateTime? startedAt,
}) => VerificationRun(
  id: id,
  title: 'Verify $id',
  target: target ?? const VerificationTarget.browser('https://example.com'),
  sessionId: sessionId,
  startedAt: startedAt ?? _t0,
  artifactDirectory: r'C:\support\verification\' + id,
);

void main() {
  late AppDatabase db;
  late VerificationDao dao;

  setUp(() {
    db = AppDatabase.memory();
    dao = VerificationDao(db);
  });

  tearDown(() => db.close());

  test('schema v11 is the current version', () {
    expect(db.schemaVersion, 11);
  });

  test('a run round-trips with its target', () {
    dao.insertRun(
      _run(
        'run-a',
        target: const VerificationTarget.device(
          serial: 'ABC123',
          packageName: 'com.example.app',
        ),
      ),
    );

    final read = dao.getRun('run-a')!;
    expect(read.target.kind, VerificationTargetKind.device);
    expect(read.target.serial, 'ABC123');
    expect(read.target.packageName, 'com.example.app');
    expect(read.isOpen, isTrue);
    expect(read.verdict, isNull);
  });

  test('finishing records the verdict, the reason and the end', () {
    dao.insertRun(_run('run-b'));
    dao.finishRun(
      'run-b',
      finishedAt: _t0.add(const Duration(seconds: 30)),
      verdict: VerificationVerdict.fail,
      reason: 'the save button did nothing',
    );

    final read = dao.getRun('run-b')!;
    expect(read.verdict, VerificationVerdict.fail);
    expect(read.reason, 'the save button did nothing');
    expect(read.duration, const Duration(seconds: 30));
    expect(read.isOpen, isFalse);
  });

  test('steps come back in the order they were taken', () {
    dao.insertRun(_run('run-c'));
    for (var i = 1; i <= 3; i++) {
      dao.insertStep(
        'run-c',
        VerificationStep(
          ordinal: i,
          kind: VerificationStepKind.click,
          summary: 'step $i',
          at: _t0.add(Duration(seconds: i)),
        ),
      );
    }

    expect(dao.getRun('run-c')!.steps.map((s) => s.summary), [
      'step 1',
      'step 2',
      'step 3',
    ]);
    expect(dao.lastOrdinal('run-c'), 3);
  });

  test('a failed step stays failed', () {
    dao.insertRun(_run('run-d'));
    dao.insertStep(
      'run-d',
      VerificationStep(
        ordinal: 1,
        kind: VerificationStepKind.click,
        summary: 'Clicked #save',
        detail: 'a cookie banner covered it',
        ok: false,
        at: _t0,
      ),
    );

    final step = dao.getRun('run-d')!.steps.single;
    expect(step.ok, isFalse);
    expect(step.detail, 'a cookie banner covered it');
  });

  test('an unknown step kind reads as "other" rather than throwing', () {
    dao.insertRun(_run('run-e'));
    db.execute(
      'INSERT INTO verification_steps '
      '(run_id, ordinal, kind, summary, ok, at) VALUES (?, ?, ?, ?, ?, ?);',
      ['run-e', 1, 'teleport', 'from the future', 1, _t0.toIso8601String()],
    );

    expect(dao.getRun('run-e')!.steps.single.kind, VerificationStepKind.other);
  });

  test('artifacts record where the file is, never the bytes', () {
    dao.insertRun(_run('run-f'));
    dao.insertArtifact(
      VerificationArtifact(
        id: 'run-f:001-screenshot.png',
        runId: 'run-f',
        kind: VerificationArtifactKind.screenshot,
        label: 'Screenshot of the page',
        relativePath: '001-screenshot.png',
        byteSize: 2048,
        at: _t0,
        stepOrdinal: 1,
      ),
    );

    final artifact = dao.getRun('run-f')!.artifacts.single;
    expect(artifact.relativePath, '001-screenshot.png');
    expect(artifact.sizeLabel, '2.0 KB');
    expect(artifact.stepOrdinal, 1);
    // The schema must have nowhere to put bytes.
    final columns = db.query('PRAGMA table_info(verification_artifacts);');
    expect(columns.map((c) => c['type']), isNot(contains('BLOB')));
  });

  test('deleting a run takes its steps and artifacts with it', () {
    dao.insertRun(_run('run-g'));
    dao.insertStep(
      'run-g',
      VerificationStep(
        ordinal: 1,
        kind: VerificationStepKind.note,
        summary: 'looked',
        at: _t0,
      ),
    );
    dao.insertArtifact(
      VerificationArtifact(
        id: 'run-g:a',
        runId: 'run-g',
        kind: VerificationArtifactKind.logcat,
        label: 'log',
        relativePath: 'log.txt',
        byteSize: 10,
        at: _t0,
      ),
    );

    dao.deleteRun('run-g');

    expect(dao.getRun('run-g'), isNull);
    expect(dao.stepsFor('run-g'), isEmpty);
    expect(dao.artifactsFor('run-g'), isEmpty);
  });

  test('runs list newest first, and can be narrowed to one session', () {
    dao.insertRun(_run('run-old', startedAt: _t0));
    dao.insertRun(
      _run(
        'run-new',
        startedAt: _t0.add(const Duration(hours: 1)),
        sessionId: 'S1',
      ),
    );
    dao.insertRun(
      _run(
        'run-other',
        startedAt: _t0.add(const Duration(hours: 2)),
        sessionId: 'S2',
      ),
    );

    expect(dao.listRuns().map((r) => r.id), [
      'run-other',
      'run-new',
      'run-old',
    ]);
    expect(dao.listRuns(sessionId: 'S1').map((r) => r.id), ['run-new']);
  });

  test(
    'a session id is a plain reference, so evidence outlives the session',
    () {
      // No foreign key means no session table is needed to write one, and no
      // cascade can take the run away when the session goes.
      dao.insertRun(_run('run-h', sessionId: 'a-session-that-does-not-exist'));
      expect(dao.getRun('run-h')!.sessionId, 'a-session-that-does-not-exist');
    },
  );

  test('a run can be attached to a session after the fact', () {
    dao.insertRun(_run('run-i'));
    dao.updateSessionId('run-i', 'S9');
    expect(dao.getRun('run-i')!.sessionId, 'S9');
    dao.updateSessionId('run-i', null);
    expect(dao.getRun('run-i')!.sessionId, isNull);
  });

  test('a prefix finds one run, and says so when it finds several', () {
    dao.insertRun(_run('run-20260830-120000-001'));
    dao.insertRun(_run('run-20260830-120000-002'));
    dao.insertRun(_run('run-20260831-090000-001'));

    expect(dao.findByPrefix('run-20260831'), hasLength(1));
    expect(dao.findByPrefix('run-20260830'), hasLength(2));
    expect(dao.findByPrefix('nope'), isEmpty);
  });

  test('a prefix full of wildcards matches literally, not as a pattern', () {
    dao.insertRun(_run('run-a'));
    expect(dao.findByPrefix('%'), isEmpty);
    expect(dao.findByPrefix('_un-a'), isEmpty);
  });

  test('the open run is the one nothing finished', () {
    dao.insertRun(_run('run-done'));
    dao.finishRun(
      'run-done',
      finishedAt: _t0,
      verdict: VerificationVerdict.pass,
    );
    expect(dao.openRun(), isNull);

    dao.insertRun(
      _run('run-open', startedAt: _t0.add(const Duration(days: 1))),
    );
    expect(dao.openRun()!.id, 'run-open');
  });
}
