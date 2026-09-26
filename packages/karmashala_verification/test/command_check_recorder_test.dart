import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:karmashala_verification/artifacts.dart';
import 'package:karmashala_verification/command_checks.dart';
import 'package:karmashala_verification/store.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:test/test.dart';

void main() {
  final at = DateTime.utc(2026, 9, 25, 10);
  late AppDatabase db;
  late Directory root;
  late CommandCheckRecorder recorder;
  var changes = 0;
  var ids = 0;

  setUp(() {
    db = AppDatabase.memory();
    root = Directory.systemTemp.createTempSync('command-checks');
    recorder = CommandCheckRecorder(
      StoreVerificationRecords(VerificationDao(db)),
      VerificationArtifactStore(root),
      newId: () => 'run-${++ids}',
      now: () => at,
      onChanged: () => changes++,
    );
  });
  tearDown(() {
    db.close();
    root.deleteSync(recursive: true);
  });

  test('the worst verdict wins: fail, then inconclusive, then pass', () {
    const pass = VerificationVerdict.pass;
    const fail = VerificationVerdict.fail;
    const unknown = VerificationVerdict.inconclusive;
    expect(worstVerdict([pass, pass]), pass);
    expect(worstVerdict([pass, unknown]), unknown);
    expect(worstVerdict([unknown, fail, pass]), fail);
    expect(worstVerdict(const []), unknown);
    expect(
      const CommandCheck(name: 'x', command: ['x'], refusal: 'no').verdict,
      unknown,
    );
    expect(const CommandCheck(name: 'x', command: ['x']).verdict, unknown);
  });

  test('a batch is one run, with a step and an output per check', () async {
    final run = await recorder.recordBatch(
      title: 'Project checks · Work',
      startedAt: at,
      sessionId: 's1',
      producedBySessionId: kAppVerifierId,
      checks: const [
        CommandCheck(
          name: 'tests',
          command: ['make', 'test'],
          exitCode: 0,
          output: 'ok',
        ),
        CommandCheck(name: 'lint', command: ['make', 'lint'], exitCode: 1),
      ],
    );
    expect(run.verdict, VerificationVerdict.fail);
    expect(run.reason, '1 of 2 passed; not passed: lint.');
    expect(run.attribution, VerdictAttribution.app);
    expect(VerificationDao(db).stepsFor(run.id), hasLength(2));
    expect(VerificationDao(db).artifactsFor(run.id), hasLength(1));
    expect(changes, 1);
  });

  test('one gate whose exit nobody saw is inconclusive', () async {
    final run = await recorder.recordOne(
      title: 'tests',
      command: const ['make', 'test'],
      workingDirectory: '/src',
      environmentId: 'local',
      startedAt: at,
      exitCode: null,
    );
    expect(run.verdict, VerificationVerdict.inconclusive);
    expect(run.reason, contains('stopped without an exit code'));
  });
}
