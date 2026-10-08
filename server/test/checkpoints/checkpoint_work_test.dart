// Real git work: under a busy machine (several suites at once) it can pass
// the default 30 s, which is load, not a failure.
@Timeout.factor(4)
library;

import 'dart:io';

import 'package:agent_cli/descriptors.dart' show AgentActivityStatus;
import 'package:agent_cli/process.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_checkpoints/store.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/events.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'checkpoint_fixtures.dart';

/// The checkpoint work a client asks the server for, over the data API —
/// each answered when its git work is done, and each row it writes told.
void main() {
  late CheckpointWorld w;

  setUp(() async => w = await CheckpointWorld.create());
  tearDown(() => w.close());

  String readme() => File(p.join(w.hub, 'README.md')).readAsStringSync();
  void writeReadme(String text) =>
      File(p.join(w.hub, 'README.md')).writeAsStringSync(text);

  /// A checkpoint row on the SSH host, as another server recorded it.
  Checkpoint onTheBox() => CheckpointDao(w.db).insert(
    Checkpoint(
      id: 'remote1',
      sessionId: 's1',
      repository: const EnvironmentPath(environmentId: 'box', path: '/srv/app'),
      sequence: 0,
      treeSha: 't',
      commitSha: 'c',
      parentCommitSha: null,
      headSha: null,
      reason: CheckpointReason.turn,
      createdAt: w.at,
    ),
  );

  Matcher refused(DataRefusalCode code, String words) => throwsA(
    isA<DataRefused>()
        .having((r) => r.code, 'code', code)
        .having((r) => r.message, 'message', startsWith(words)),
  );

  group('capture now', () {
    test('records the working tree, answered when done', () async {
      final taken = await w.ask(const CheckpointCapture('s1'));
      expect(taken, isNotNull);
      expect(taken!.reason, CheckpointReason.manual);
      expect(taken.repository.path, w.hub);
      expect(
        w.told.whereType<CheckpointRecorded>().single.checkpoint.id,
        taken.id,
      );
    }, skip: hasGit ? false : 'git is not on PATH');

    test('a tree that has not moved answers null', () async {
      await w.ask(const CheckpointCapture('s1'));
      expect(await w.ask(const CheckpointCapture('s1')), isNull);
      expect(await w.ask(const CheckpointCapture('no-such-session')), isNull);
    }, skip: hasGit ? false : 'git is not on PATH');

    // One round on real git, slowed as a loaded machine is: that the second
    // waits for the first is proven without timing in checkpoint_service_test.
    test('two sessions in one checkout capturing at once both record, never '
        'one locked out of the private index', () async {
      w.addSession('s2', workingDirectory: w.hub);
      w.runners
        ..slow = true
        ..delay = const Duration(seconds: 2);
      writeReadme('hub 1\n');
      for (var k = 0; k < 20; k++) {
        File(p.join(w.hub, 'f$k.txt')).writeAsStringSync('1 $k\n');
      }
      final both = await Future.wait([
        w.checkpoints.recorder.captureNow('s1'),
        w.checkpoints.recorder.captureNow('s2'),
      ]);
      expect(both, everyElement(isNotNull));
      expect(w.log.where((line) => line.contains('could not')), isEmpty);
    }, skip: hasGit ? false : 'git is not on PATH');

    test('without a recorder the request is refused, not left open', () async {
      w.data.checkpointWork = null;
      await expectLater(
        w.ask(const CheckpointCapture('s1')),
        refused(DataRefusalCode.unavailable, 'this server keeps no'),
      );
    });
  });

  group('a labelled capture is a decision', () {
    List<DecisionRecord> decisions() => [
      for (final c in w.told.whereType<DecisionRecorded>()) c.decision,
    ];

    test('a checkpoint taken with a reason is filed, as decided by whom '
        'the client says', () async {
      final checkpoint = await w.ask(
        const CheckpointCapture(
          's1',
          label: 'Before the parser rewrite — this one works.',
          decidedBy: 'the user',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final decision = decisions().single;
      expect(decision.kind, DecisionKind.checkpointMarked);
      expect(decision.summary, 'Before the parser rewrite — this one works.');
      expect(decision.decidedBy, 'the user');
      expect(decision.origin, DecisionOrigin.checkpoint);
      expect(decision.originId, checkpoint!.id);
      expect(decision.sessionId, 's1');
    }, skip: hasGit ? false : 'git is not on PATH');

    test('an agent asking for one is attributed to the agent', () async {
      await w.ask(
        const CheckpointCapture(
          's1',
          label: 'Green build, before the risky change.',
          decidedBy: 'an agent in session s1',
          decidedBySessionId: 's1',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final decision = decisions().single;
      expect(decision.recordedBySessionId, 's1');
      expect(decision.decidedBy, contains('s1'));
    }, skip: hasGit ? false : 'git is not on PATH');

    test('a blank label, no label, or a turn records nothing', () async {
      expect(
        await w.ask(const CheckpointCapture('s1', label: '  ')),
        isNotNull,
      );
      writeReadme('moved\n');
      expect(await w.ask(const CheckpointCapture('s1')), isNotNull);
      writeReadme('moved again\n');
      await w.turn(prompt: 'Turn 4');
      await Future<void>.delayed(Duration.zero);
      expect(w.rows(), hasLength(3));
      expect(decisions(), isEmpty);
    }, skip: hasGit ? false : 'git is not on PATH');
  });

  group('diff and restore', () {
    test('a diff is what changed since the checkpoint before it', () async {
      await w.ask(const CheckpointCapture('s1'));
      writeReadme('hub\nsecond line\n');
      final second = (await w.ask(const CheckpointCapture('s1')))!;
      final diff = await w.ask(CheckpointDiff(second.id));
      expect(diff, contains('+second line'));
      expect(diff, contains('README.md'));
    }, skip: hasGit ? false : 'git is not on PATH');

    test('a moved tree is refused in the service\'s words, with the safety '
        'checkpoint; confirmed, it restores', () async {
      final target = (await w.ask(const CheckpointCapture('s1')))!;
      writeReadme('hub\nnewer work\n');

      final refused = await w.ask(CheckpointRestore(target.id));
      final conflict = refused.conflict!;
      expect(
        conflict.message,
        checkpointRestoreRefusal(
          treeMovedSinceLastCheckpoint: true,
          safetySequence: conflict.safetyCheckpoint!.sequence,
        ),
      );
      expect(conflict.safetyCheckpoint!.reason, CheckpointReason.safety);
      expect(readme(), 'hub\nnewer work\n', reason: 'nothing was changed');
      expect(() => refused.outcomeOrThrow, throwsA(isA<CheckpointConflict>()));

      final done = (await w.ask(
        CheckpointRestore(target.id, confirm: true),
      )).outcomeOrThrow;
      expect(done.alreadyThere, isFalse);
      expect(done.files.single.path, 'README.md');
      expect(readme(), 'hub\n');
      expect(restoreOutcomeMessage(done), startsWith('Restored 1 file.'));
    }, skip: hasGit ? false : 'git is not on PATH');

    test('a client\'s restore while the session\'s turn runs is refused, and '
        'allowed once the turn ends', () async {
      final target = (await w.ask(const CheckpointCapture('s1')))!;
      writeReadme('hub\nnewer\n');
      w.checkpoints.recorder.observe('s1', AgentActivityStatus.working);
      await w.settle();

      await expectLater(
        w.ask(CheckpointRestore(target.id, confirm: true)),
        refused(DataRefusalCode.invalid, 'A turn of "session s1"'),
      );
      expect(readme(), 'hub\nnewer\n');

      w.checkpoints.recorder.observe('s1', AgentActivityStatus.idle);
      await w.settle();
      final done = (await w.ask(
        CheckpointRestore(target.id, confirm: true),
      )).outcomeOrThrow;
      expect(done.alreadyThere, isFalse);
      expect(readme(), 'hub\n');
    }, skip: hasGit ? false : 'git is not on PATH');

    test('a per-path restore of a path in neither tree says so; an unchanged '
        'one already matches', () async {
      final target = (await w.ask(const CheckpointCapture('s1')))!;
      File(p.join(w.hub, 'other.txt')).writeAsStringSync('o\n');
      await w.ask(const CheckpointCapture('s1'));

      await expectLater(
        w.ask(
          CheckpointRestore(target.id, paths: const ['other.txt', 'nope.txt']),
        ),
        throwsA(
          isA<DataRefused>()
              .having((r) => r.code, 'code', DataRefusalCode.notFound)
              .having(
                (r) => r.message,
                'message',
                allOf(contains('nope.txt'), contains('not found')),
              ),
        ),
      );
      expect(
        File(p.join(w.hub, 'other.txt')).existsSync(),
        isTrue,
        reason: 'nothing was restored',
      );

      final unchanged = (await w.ask(
        CheckpointRestore(target.id, paths: const ['README.md']),
      )).outcomeOrThrow;
      expect(unchanged.alreadyThere, isTrue);
    }, skip: hasGit ? false : 'git is not on PATH');

    test('a per-path restore touches only the file it was asked for', () async {
      File(p.join(w.hub, 'other.txt')).writeAsStringSync('o1\n');
      final target = (await w.ask(const CheckpointCapture('s1')))!;
      writeReadme('hub\nchanged\n');
      File(p.join(w.hub, 'other.txt')).writeAsStringSync('o2\n');
      await w.ask(const CheckpointCapture('s1'));

      final done = (await w.ask(
        CheckpointRestore(target.id, paths: const ['other.txt']),
      )).outcomeOrThrow;
      expect(done.files.map((f) => f.path), ['other.txt']);
      expect(File(p.join(w.hub, 'other.txt')).readAsStringSync(), 'o1\n');
      expect(readme(), 'hub\nchanged\n');
    }, skip: hasGit ? false : 'git is not on PATH');

    test('a per-path restore on Windows takes the path spelled with '
        'backslashes', () async {
      final file = File(p.join(w.hub, 'lib', 'a.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('one\n');
      final target = (await w.ask(const CheckpointCapture('s1')))!;
      file.writeAsStringSync('two\n');
      await w.ask(const CheckpointCapture('s1'));

      final done = (await w.ask(
        CheckpointRestore(target.id, paths: const [r'lib\a.txt']),
      )).outcomeOrThrow;
      expect(done.alreadyThere, isFalse);
      expect(done.files.map((f) => f.path), ['lib/a.txt']);
      expect(file.readAsStringSync(), 'one\n');
    }, skip: !hasGit || !Platform.isWindows ? 'needs git, on Windows' : false);

    test('a per-path restore puts back a binary file', () async {
      final logo = File(p.join(w.hub, 'logo.bin'))
        ..writeAsBytesSync([0, 1, 2, 3, 0, 255]);
      final target = (await w.ask(const CheckpointCapture('s1')))!;
      logo.writeAsBytesSync([0, 9, 9, 9, 0, 255, 7]);
      await w.ask(const CheckpointCapture('s1'));

      final done = (await w.ask(
        CheckpointRestore(target.id, paths: const ['logo.bin']),
      )).outcomeOrThrow;
      expect(done.files.map((f) => f.path), ['logo.bin']);
      expect(logo.readAsBytesSync(), [0, 1, 2, 3, 0, 255]);
    }, skip: hasGit ? false : 'git is not on PATH');

    test('a per-path restore of a name git quotes is done, not "already '
        'there"', () async {
      final cafe = File(p.join(w.hub, 'café.txt'))..writeAsStringSync('one\n');
      final target = (await w.ask(const CheckpointCapture('s1')))!;
      cafe.writeAsStringSync('two\n');
      await w.ask(const CheckpointCapture('s1'));

      final done = (await w.ask(
        CheckpointRestore(target.id, paths: const ['café.txt']),
      )).outcomeOrThrow;
      expect(done.alreadyThere, isFalse);
      expect(done.files.map((f) => f.path), ['café.txt']);
      expect(cafe.readAsStringSync(), 'one\n');
    }, skip: hasGit ? false : 'git is not on PATH');

    test('an unknown id is not found, in the tool\'s words', () async {
      await expectLater(
        w.ask(const CheckpointDiff('nope')),
        refused(DataRefusalCode.notFound, 'No checkpoint with id nope.'),
      );
      await expectLater(
        w.ask(const CheckpointRestore('nope')),
        refused(DataRefusalCode.notFound, 'No checkpoint with id nope.'),
      );
    });

    test('a checkout this server cannot reach is refused in words', () async {
      final remote = onTheBox();
      for (final request in <DataRequest<Object?>>[
        CheckpointDiff(remote.id),
        CheckpointRestore(remote.id, confirm: true),
        const CheckpointCaptureBase(
          EnvironmentPath(environmentId: 'box', path: '/srv/app'),
          runId: 'run1',
          label: 'before run',
        ),
      ]) {
        await expectLater(
          w.ask(request),
          refused(
            DataRefusalCode.invalid,
            'Checkpoints are not supported for repositories on build-box',
          ),
        );
      }
    });
  });

  test('a run\'s base is recorded under the run, even unchanged', () async {
    final first = await w.ask(
      CheckpointCaptureBase(
        w.local(w.hub),
        runId: 'run1',
        label: 'Before Nightly sweep',
      ),
    );
    final again = await w.ask(
      CheckpointCaptureBase(
        w.local(w.hub),
        runId: 'run1',
        label: 'Before Nightly sweep',
      ),
    );
    expect(first!.sessionId, 'run1');
    expect(first.reason, CheckpointReason.manual);
    expect(first.label, 'Before Nightly sweep');
    expect(again, isNotNull, reason: 'undo needs a point either way');
    expect(again!.treeSha, first.treeSha);
    expect(w.rows('run1'), hasLength(2));
    expect(w.rows('s1'), isEmpty);
  }, skip: hasGit ? false : 'git is not on PATH');
}
