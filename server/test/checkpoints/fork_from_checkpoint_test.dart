import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_checkpoints/store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'checkpoint_fixtures.dart';

/// The server's half of `session_fork_from_checkpoint`: which checkpoint,
/// whether the files may be put back, and putting them back.
void main() {
  late CheckpointWorld w;

  setUp(() async => w = await CheckpointWorld.create());
  tearDown(() => w.close());

  Checkpoint row(
    String id, {
    String session = 's1',
    int? turn,
    CheckpointReason reason = CheckpointReason.turn,
    String environmentId = 'local',
  }) => CheckpointDao(w.db).insert(
    Checkpoint(
      id: id,
      sessionId: session,
      repository: EnvironmentPath(
        environmentId: environmentId,
        path: environmentId == 'local' ? w.hub : '/srv/app',
      ),
      sequence: 0,
      treeSha: 't$id',
      commitSha: 'c$id',
      parentCommitSha: null,
      headSha: null,
      reason: reason,
      createdAt: w.at,
      turn: turn,
    ),
  );

  group('the checkpoint a fork names', () {
    test('by id, or by the turn it began', () {
      row('c1', turn: 1);
      row('c2', turn: 2, reason: CheckpointReason.turnStart);
      row('c3', turn: 2);
      expect(
        w.checkpoints.forkCheckpoint(sessionId: 's1', checkpointId: 'c3').id,
        'c3',
      );
      expect(w.checkpoints.forkCheckpoint(sessionId: 's1', turn: 2).id, 'c2');
    });

    test('refuses rather than guesses, in the tool\'s words', () {
      row('c1', turn: 1);
      row('x1', session: 's9');
      Matcher says(String words) =>
          throwsA(isA<StateError>().having((e) => e.message, 'm', words));
      expect(
        () => w.checkpoints.forkCheckpoint(sessionId: 's1'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'm',
            'Name exactly one of checkpointId or turn. checkpoint_list shows '
                'both.',
          ),
        ),
      );
      expect(
        () => w.checkpoints.forkCheckpoint(
          sessionId: 's1',
          checkpointId: 'c1',
          turn: 1,
        ),
        throwsArgumentError,
      );
      expect(
        () => w.checkpoints.forkCheckpoint(sessionId: 's1', checkpointId: 'no'),
        says('No checkpoint with id no.'),
      );
      expect(
        () => w.checkpoints.forkCheckpoint(sessionId: 's1', checkpointId: 'x1'),
        says('Checkpoint x1 belongs to session s9, not s1.'),
      );
      expect(
        () => w.checkpoints.forkCheckpoint(sessionId: 's1', turn: 5),
        says('That session has no checkpoint for turn 5. It has turns 1.'),
      );
      expect(
        () => w.checkpoints.forkCheckpoint(sessionId: 's9', turn: 1),
        says(
          'That session has no checkpoint recorded against a turn, so there '
          'is no turn to fork from. Name a checkpointId from checkpoint_list '
          'instead.',
        ),
      );
    });
  });

  group('whether the files may be put back', () {
    test('a checkout nobody else is in may', () {
      expect(
        w.checkpoints.forkFileRefusal(
          row('c1'),
          sessionId: 's1',
          intoNewWorktree: false,
        ),
        isNull,
      );
    });

    test('another session working in it is named', () {
      w.addSession('s2', workingDirectory: w.hub, title: 'Nightly sweep');
      expect(
        w.checkpoints.forkFileRefusal(
          row('c1'),
          sessionId: 's1',
          intoNewWorktree: false,
        ),
        contains('"Nightly sweep" is working in this checkout'),
      );
    });

    test('a session with no directory recorded works in its repository\'s '
        'checkout, and is named too', () {
      w.addSession('s2', title: 'Old session');
      expect(
        w.checkpoints.forkFileRefusal(
          row('c1'),
          sessionId: 's1',
          intoNewWorktree: false,
        ),
        contains('"Old session" is working in this checkout'),
      );
    });

    test('a new worktree, or an SSH host, gives it up in words', () {
      expect(
        w.checkpoints.forkFileRefusal(
          row('c1'),
          sessionId: 's1',
          intoNewWorktree: true,
        ),
        contains('fresh checkout of the branch'),
      );
      expect(
        w.checkpoints.forkFileRefusal(
          row('r1', environmentId: 'box'),
          sessionId: 's1',
          intoNewWorktree: false,
        ),
        'The files were left as they are: checkpoints are not supported for '
        'repositories on build-box: they need a private git index this '
        'machine can write to.',
      );
    });
  });

  group('putting them back', () {
    test('restores the tree, and a moved tree without confirm is refused '
        'with nothing started', () async {
      final target = (await w.checkpoints.recorder.captureNow('s1'))!;
      File(p.join(w.hub, 'README.md')).writeAsStringSync('hub\nlater\n');

      Object? thrown;
      try {
        await w.checkpoints.restoreForFork(target);
      } on StateError catch (error) {
        thrown = error;
      }
      final message = (thrown! as StateError).message;
      expect(
        message,
        contains(
          'Nothing was changed and no session was started. The current '
          'working tree is saved as checkpoint ',
        ),
      );
      expect(
        File(p.join(w.hub, 'README.md')).readAsStringSync(),
        'hub\nlater\n',
      );

      final done = await w.checkpoints.restoreForFork(target, confirm: true);
      expect(done.alreadyThere, isFalse);
      expect(done.files.single.path, 'README.md');
      expect(File(p.join(w.hub, 'README.md')).readAsStringSync(), 'hub\n');
    }, skip: hasGit ? false : 'git is not on PATH');
  });
}
