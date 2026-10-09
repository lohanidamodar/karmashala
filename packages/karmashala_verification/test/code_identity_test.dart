import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:karmashala_verification/check_results.dart';
import 'package:karmashala_verification/command_checks.dart';
import 'package:karmashala_verification/artifacts.dart';
import 'package:karmashala_verification/store.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:test/test.dart';

const _head = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _other = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

CodeIdentity _identity({
  String head = _head,
  Map<String, String> dirty = const {},
  String? tree,
}) => CodeIdentity(
  environmentId: 'local',
  path: '/src/r1',
  head: head,
  tree: tree ?? dirty.entries.map((e) => '${e.key}=${e.value}').join(','),
  dirty: dirty,
  dirtyCount: dirty.length,
);

void main() {
  group('compareCodeIdentity', () {
    test('the same commit and files are fresh', () {
      final code = _identity(dirty: {'a': '1'});
      expect(
        compareCodeIdentity(code, _identity(dirty: {'a': '1'})).state,
        CodeFreshnessState.fresh,
      );
    });

    test('an edit on the same commit is stale, counted exactly', () {
      final freshness = compareCodeIdentity(
        _identity(dirty: {'a': '1', 'b': '2'}),
        _identity(dirty: {'a': '1', 'b': '3', 'c': '4'}),
      );
      expect(freshness.state, CodeFreshnessState.stale);
      expect(freshness.filesChanged, 2);
      expect(freshness.label, 'stale (2 files changed since)');
    });

    test('another commit with nothing to count is stale, uncounted', () {
      final freshness = compareCodeIdentity(
        _identity(),
        _identity(head: _other),
      );
      expect(freshness.state, CodeFreshnessState.stale);
      expect(freshness.filesChanged, isNull);
      expect(freshness.label, 'stale (code changed since)');
    });

    test('another commit counts by content across both commits', () {
      final freshness = compareCodeIdentity(
        _identity(dirty: {'a': 'x'}),
        _identity(head: _other),
        committed: {'a', 'b'},
        recordedHeadBlobs: {'a': '1', 'b': '2'},
        currentHeadBlobs: {'a': 'x', 'b': '3'},
      );
      // a: x then, x committed now — the same; b changed.
      expect(freshness.filesChanged, 1);
    });

    test('a run whose code moved is stale whatever the checkout says', () {
      final code = _identity().copyWith(changedDuringRun: true);
      final freshness = compareCodeIdentity(code, _identity());
      expect(freshness.state, CodeFreshnessState.stale);
      expect(freshness.label, 'stale (changed while it ran)');
    });

    test('nothing recorded, or nothing readable now, is unknown', () {
      expect(
        compareCodeIdentity(null, _identity()).state,
        CodeFreshnessState.unknown,
      );
      expect(
        compareCodeIdentity(_identity(), null).state,
        CodeFreshnessState.unknown,
      );
    });

    test('another checkout is never the same code', () {
      final elsewhere = CodeIdentity(
        environmentId: 'local',
        path: '/src/other',
        head: _head,
        tree: '',
        dirty: const {},
      );
      expect(compareCodeIdentity(_identity(), elsewhere).isStale, isTrue);
    });
  });

  test('identity and freshness survive their JSON', () {
    final code = _identity(dirty: {'a': '1'}).copyWith(changedDuringRun: true);
    final back = CodeIdentity.fromJson(code.toJson())!;
    expect(back.sameCode(code), isTrue);
    expect(back.changedDuringRun, isTrue);
    expect(back.dirty, {'a': '1'});
    const freshness = CodeFreshness.stale('x', filesChanged: 3);
    expect(CodeFreshness.fromJson(freshness.toJson()), freshness);
    expect(CodeIdentity.fromJson({'path': 1}), isNull);
  });

  test('settledAgainst marks a run only when the code moved', () {
    final code = _identity();
    expect(code.settledAgainst(_identity()).changedDuringRun, isFalse);
    expect(code.settledAgainst(null).changedDuringRun, isFalse);
    expect(
      code.settledAgainst(_identity(head: _other)).changedDuringRun,
      isTrue,
    );
  });

  group('stored', () {
    late AppDatabase db;
    late Directory artifacts;

    setUp(() {
      db = AppDatabase.memory();
      db.execute('PRAGMA foreign_keys = OFF;');
      artifacts = Directory.systemTemp.createTempSync('code-identity');
    });
    tearDown(() {
      db.close();
      artifacts.deleteSync(recursive: true);
    });

    VerificationRun run(String id, {CodeIdentity? identity}) => VerificationRun(
      id: id,
      title: 'Checks',
      target: const VerificationTarget.change(),
      startedAt: DateTime.utc(2026, 10, 9),
      artifactDirectory: '/tmp/$id',
      identity: identity,
    );

    test('a run keeps its identity, and the wire carries it', () {
      final dao = VerificationDao(db);
      final code = _identity(dirty: {'a': '1'});
      dao.insertRun(run('r1', identity: code));
      final stored = dao.getRun('r1')!;
      expect(stored.identity!.sameCode(code), isTrue);
      final wire = verificationRunFromJson(verificationRunToJson(stored));
      expect(wire.identity!.sameCode(code), isTrue);
      expect(sameVerificationHeader(wire, stored), isTrue);
    });

    test('an old row reads as no identity — "version unknown"', () {
      final dao = VerificationDao(db);
      dao.insertRun(run('old'));
      expect(dao.getRun('old')!.identity, isNull);
    });

    test('finishing with an identity records that the code moved', () {
      final dao = VerificationDao(db);
      final code = _identity();
      dao.insertRun(run('r1', identity: code));
      dao.finishRun(
        'r1',
        finishedAt: DateTime.utc(2026, 10, 9, 1),
        verdict: VerificationVerdict.pass,
        identity: code.copyWith(changedDuringRun: true),
      );
      expect(dao.getRun('r1')!.identity!.changedDuringRun, isTrue);
      dao.finishRun(
        'r1',
        finishedAt: DateTime.utc(2026, 10, 9, 2),
        verdict: VerificationVerdict.pass,
      );
      expect(dao.getRun('r1')!.identity, isNotNull);
    });

    test('a check reading keeps its identity', () {
      final dao = CheckResultDao(db);
      final code = _identity(dirty: {'a': '1'});
      dao.record(
        RecordedCheckResults(
          repositoryId: 'r1',
          sessionId: 's1',
          checkName: 'analyze',
          recordedAt: DateTime.utc(2026, 10, 9),
          results: const CheckResults(format: CheckOutputFormat.analyzerText),
          identity: code,
        ),
      );
      final reading = dao.forSession('s1').single;
      expect(reading.identity!.sameCode(code), isTrue);
      expect(reading.toJson()['code'], code.label);
    });

    test('a pass over code that moved while it ran is inconclusive', () async {
      final recorder = CommandCheckRecorder(
        StoreVerificationRecords(VerificationDao(db)),
        VerificationArtifactStore(artifacts),
        newId: () => 'vr-1',
        now: () => DateTime.utc(2026, 10, 9),
      );
      final stored = await recorder.recordOne(
        title: 'tests',
        command: const ['make', 'test'],
        workingDirectory: '/src/r1',
        environmentId: 'local',
        startedAt: DateTime.utc(2026, 10, 9),
        exitCode: 0,
        identity: _identity().copyWith(changedDuringRun: true),
      );
      expect(stored.verdict, VerificationVerdict.inconclusive);
      expect(stored.reason, contains('changed while it ran'));
      expect(stored.identity!.changedDuringRun, isTrue);
    });

    test('a batch over code that held still keeps its pass', () async {
      final recorder = CommandCheckRecorder(
        StoreVerificationRecords(VerificationDao(db)),
        VerificationArtifactStore(artifacts),
        newId: () => 'vr-2',
        now: () => DateTime.utc(2026, 10, 9),
      );
      final stored = await recorder.recordBatch(
        title: 'checks',
        startedAt: DateTime.utc(2026, 10, 9),
        checks: const [
          CommandCheck(name: 'tests', command: ['make'], exitCode: 0),
        ],
        identity: _identity(),
      );
      expect(stored.verdict, VerificationVerdict.pass);
      expect(stored.identity, isNotNull);
    });
  });
}
