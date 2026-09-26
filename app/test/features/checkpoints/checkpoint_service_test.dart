import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_git/git.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/workspace_mirror.dart';

/// [GitFiles] that keeps everything in a map, so a test can assert on the two
/// files the checkpoint machinery writes without going anywhere near a disk.
class RecordingGitFiles implements GitFiles {
  final Map<String, String> written = {};
  final List<String> directories = [];

  @override
  Future<void> createDirectory(String path) async => directories.add(path);

  @override
  Future<bool> exists(String path) async => written.containsKey(path);

  @override
  Future<PathEntry> typeOf(String path) async =>
      throw UnimplementedError('the checkpoint path never stats');

  @override
  Future<void> writeString(String path, String contents) async =>
      written[path] = contents;

  @override
  Future<String?> readString(String path) async => written[path];
}

class FixedClock implements Clock {
  FixedClock(this.now);
  final DateTime now;
  @override
  DateTime nowUtc() => now;
}

const _repo = EnvironmentPath(environmentId: 'windows', path: r'C:\src\demo');

void main() {
  late AppDatabase db;
  late CheckpointDao dao;
  late FakeCommandRunner runner;
  late RecordingGitFiles files;
  late CheckpointService service;
  late List<String> trees;
  late int ids;

  /// Answers the handful of git calls a capture makes. `trees` is popped so a
  /// test can decide whether the working tree moved between captures.
  CommandResult respond(CommandRequest request) {
    final args = request.arguments;
    String out(String value) =>
        CommandResult(exitCode: 0, stdout: value, stderr: '').stdout;
    if (args.contains('--absolute-git-dir')) {
      return CommandResult(
        exitCode: 0,
        stdout: out('C:/src/demo/.git'),
        stderr: '',
      );
    }
    if (args.contains('--git-common-dir')) {
      return CommandResult(
        exitCode: 0,
        stdout: out('C:/src/demo/.git'),
        stderr: '',
      );
    }
    if (args.contains('write-tree')) {
      return CommandResult(
        exitCode: 0,
        stdout: trees.length > 1 ? trees.removeAt(0) : trees.first,
        stderr: '',
      );
    }
    if (args.contains('commit-tree')) {
      return const CommandResult(exitCode: 0, stdout: 'commit1', stderr: '');
    }
    if (args.contains('rev-parse') && args.contains('--verify')) {
      return const CommandResult(exitCode: 0, stdout: 'head1', stderr: '');
    }
    if (args.contains('--numstat')) {
      return const CommandResult(
        exitCode: 0,
        stdout: '3\t1\tlib/a.dart\n-\t-\tlib/b.dart\n',
        stderr: '',
      );
    }
    if (args.contains('--name-status')) {
      return const CommandResult(
        exitCode: 0,
        stdout: 'M\tlib/a.dart\nA\tlib/b.dart\n',
        stderr: '',
      );
    }
    if (args.contains('diff')) {
      return const CommandResult(
        exitCode: 0,
        stdout:
            'diff --git a/lib/a.dart b/lib/a.dart\n'
            'index 111..222 100644\n'
            '--- a/lib/a.dart\n'
            '+++ b/lib/a.dart\n'
            '@@ -1 +1 @@\n'
            '-before\n'
            '+after\n',
        stderr: '',
      );
    }
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  setUp(() {
    db = AppDatabase.memory();
    dao = CheckpointDao(db);
    // The checkpoint rows' foreign key reaches the environment in the store.
    final server = FakeDataServer()..mirrorInto(db);
    server.environmentRows.upsert(
      ExecutionEnvironment(
        id: 'windows',
        kind: EnvironmentKind.windowsNative,
        name: 'Windows',
        createdAt: DateTime.utc(2026),
      ),
    );
    trees = ['tree1'];
    ids = 0;
    runner = FakeCommandRunner(responder: respond);
    files = RecordingGitFiles();
    service = CheckpointService(
      runnerFactory: FakeCommandRunnerFactory(fallback: runner),
      environmentOf: server.environmentRows.getById,
      dao: dao,
      clock: FixedClock(DateTime.utc(2026, 8, 30, 12)),
      newId: () => 'ckpt${++ids}',
      files: files,
    );
  });
  tearDown(() => db.close());

  List<List<String>> gitCalls() => [
    for (final r in runner.requests) r.arguments,
  ];

  group('capture', () {
    test('snapshots the working tree without touching the user index', () async {
      final checkpoint = await service.capture(_repo, sessionId: 's1');

      expect(checkpoint, isNotNull);
      expect(checkpoint!.treeSha, 'tree1');
      expect(checkpoint.commitSha, 'commit1');
      expect(checkpoint.sequence, 1);
      expect(checkpoint.reason, CheckpointReason.turn);
      expect(checkpoint.files.map((f) => f.path), ['lib/a.dart', 'lib/b.dart']);

      final calls = gitCalls();
      // Every staging call is scoped to the private git directory. This is the
      // whole safety property: without `--git-dir` this would be `git add -A`
      // against the user's own index.
      for (final call in calls.where((c) => c.contains('add'))) {
        expect(
          call,
          contains('--git-dir=C:/src/demo/.git/karmashala'),
          reason: 'a checkpoint must never stage into the user index',
        );
        expect(call, contains('--work-tree=${_repo.path}'));
      }
      expect(calls.any((c) => c.contains('add')), isTrue);

      // And nothing that moves the user's repository was run at all.
      for (final forbidden in [
        'commit',
        'checkout',
        'reset',
        'stash',
        'restore',
        'switch',
        'clean',
      ]) {
        expect(
          calls.any((c) => c.contains(forbidden)),
          isFalse,
          reason: 'a checkpoint must not run git $forbidden',
        );
      }
    });

    test('creates the private git directory once, with two files', () async {
      await service.capture(_repo, sessionId: 's1');
      expect(files.directories, ['C:/src/demo/.git/karmashala']);
      expect(
        files.written['C:/src/demo/.git/karmashala/commondir'],
        'C:/src/demo/.git\n',
      );
      expect(
        files.written['C:/src/demo/.git/karmashala/HEAD'],
        'ref: refs/heads/karmashala-checkpoints\n',
      );

      trees = ['tree2'];
      await service.capture(_repo, sessionId: 's1');
      expect(
        files.directories.length,
        1,
        reason: 'the second capture reuses the directory',
      );
    });

    test('anchors the chain with one ref per session', () async {
      await service.capture(_repo, sessionId: 's1');
      final refCalls = gitCalls().where((c) => c.contains('update-ref'));
      expect(refCalls, hasLength(1));
      expect(
        refCalls.single,
        containsAllInOrder([
          'update-ref',
          'refs/karmashala/checkpoints/s1',
          'commit1',
        ]),
      );
    });

    test('records nothing when the turn changed nothing', () async {
      final first = await service.capture(_repo, sessionId: 's1');
      expect(first, isNotNull);
      // The same tree comes back, so there is nothing new to undo.
      final second = await service.capture(_repo, sessionId: 's1');
      expect(second, isNull);
      expect(dao.forSession('s1'), hasLength(1));
    });

    test('chains each checkpoint onto the one before it', () async {
      await service.capture(_repo, sessionId: 's1');
      trees = ['tree2'];
      final second = await service.capture(_repo, sessionId: 's1');
      expect(second!.sequence, 2);
      expect(second.parentCommitSha, 'commit1');
      final commitCalls = gitCalls().where((c) => c.contains('commit-tree'));
      expect(commitCalls.last, containsAllInOrder(['-p', 'commit1']));
    });

    test('a session with no checkpoints yet measures against HEAD', () async {
      await service.capture(_repo, sessionId: 's1');
      final nameStatus = gitCalls().firstWhere(
        (c) => c.contains('--name-status'),
      );
      expect(nameStatus, containsAllInOrder(['head1', 'tree1']));
    });
  });

  group('restore', () {
    test('refuses when the tree moved, and saves it first', () async {
      final target = (await service.capture(_repo, sessionId: 's1'))!;
      // The working tree has moved on since that checkpoint.
      trees = ['tree2'];

      await expectLater(
        service.restore(target),
        throwsA(isA<CheckpointConflict>()),
      );

      final all = dao.forSession('s1');
      expect(all, hasLength(2));
      expect(all.last.reason, CheckpointReason.safety);
      expect(all.last.treeSha, 'tree2');
      expect(
        gitCalls().any((c) => c.contains('apply')),
        isFalse,
        reason: 'a refused restore must change nothing',
      );
    });

    test('applies the diff backwards once confirmed', () async {
      final target = (await service.capture(_repo, sessionId: 's1'))!;
      trees = ['tree2'];

      final outcome = await service.restore(target, confirm: true);

      expect(outcome.alreadyThere, isFalse);
      expect(outcome.safetyCheckpoint, isNotNull);
      final apply = gitCalls().firstWhere((c) => c.contains('apply'));
      expect(apply, contains('-R'));
      expect(
        apply,
        isNot(contains('--cached')),
        reason: 'restoring the working tree must leave the index alone',
      );
      expect(apply.last, 'C:/src/demo/.git/karmashala/apply.patch');
      // The patch is the checkpoint-to-now diff, reversed by git.
      final diff = gitCalls().lastWhere(
        (c) => c.contains('diff') && c.contains('--binary'),
      );
      expect(diff, containsAllInOrder(['tree1', 'tree2']));
    });

    test('does nothing when the tree already is the checkpoint', () async {
      final target = (await service.capture(_repo, sessionId: 's1'))!;
      final outcome = await service.restore(target);
      expect(outcome.alreadyThere, isTrue);
      expect(outcome.safetyCheckpoint, isNull);
      expect(gitCalls().any((c) => c.contains('apply')), isFalse);
    });
  });

  group('hunk operations', () {
    test('staging goes through the index, and only the index', () async {
      await service.stage(_repo, [
        const HunkSelection('lib/a.dart', hunks: [0]),
      ]);
      final apply = gitCalls().firstWhere((c) => c.contains('apply'));
      expect(apply, contains('--cached'));
      expect(apply, isNot(contains('-R')));
      expect(
        files.written['C:/src/demo/.git/karmashala/apply.patch'],
        contains('@@ -1 +1 @@'),
      );
    });

    test('unstaging is the same patch, backwards', () async {
      await service.unstage(_repo, [const HunkSelection('lib/a.dart')]);
      final apply = gitCalls().firstWhere((c) => c.contains('apply'));
      expect(apply, contains('--cached'));
      expect(apply, contains('-R'));
      final diff = gitCalls().firstWhere((c) => c.contains('diff'));
      expect(diff, contains('--staged'));
    });

    test(
      'reverting a hunk checkpoints first when it knows the session',
      () async {
        await service.revert(_repo, [
          const HunkSelection('lib/a.dart', hunks: [0]),
        ], sessionId: 's1');
        final saved = dao.forSession('s1');
        expect(saved, hasLength(1));
        expect(saved.single.reason, CheckpointReason.safety);
        final apply = gitCalls().firstWhere((c) => c.contains('apply'));
        expect(apply, contains('-R'));
        expect(apply, isNot(contains('--cached')));
      },
    );

    test('a selection that matches nothing runs no git apply', () async {
      await service.stage(_repo, [const HunkSelection('lib/nowhere.dart')]);
      expect(gitCalls().any((c) => c.contains('apply')), isFalse);
    });
  });

  group('the DAO', () {
    test('numbers each session independently', () {
      var n = 0;
      Checkpoint make(String session) => Checkpoint(
        id: 'id-$session-${++n}',
        sessionId: session,
        repository: _repo,
        sequence: 0,
        treeSha: 't',
        commitSha: 'c',
        parentCommitSha: null,
        headSha: null,
        reason: CheckpointReason.turn,
        createdAt: DateTime.utc(2026),
      );
      expect(dao.insert(make('a')).sequence, 1);
      expect(dao.insert(make('a')).sequence, 2);
      expect(dao.insert(make('b')).sequence, 1);
      expect(dao.latestFor('a')!.sequence, 2);
      expect(dao.sessionsWithCheckpoints(), containsAll(['a', 'b']));
    });
  });

  group('turns and repositories', () {
    const other = EnvironmentPath(
      environmentId: 'windows',
      path: r'C:\src\demo\packages\nested',
    );

    test('each repository keeps its own chain', () async {
      // Two repositories that happen to hold the same tree are still two
      // chains: comparing across them would skip a real change.
      final first = await service.capture(_repo, sessionId: 's1');
      final nested = await service.capture(other, sessionId: 's1');
      expect(first, isNotNull);
      expect(nested, isNotNull);
      expect(nested!.parentCommitSha, isNull);
      expect(await service.capture(_repo, sessionId: 's1'), isNull);
      expect(dao.repositoriesFor('s1'), [other, _repo]);
      expect(dao.forRepository('s1', other).single.id, nested.id);
    });

    test('records the turn, its prompt and each file\'s line counts', () async {
      final checkpoint = await service.capture(
        _repo,
        sessionId: 's1',
        reason: CheckpointReason.turnStart,
        turn: 4,
        prompt: 'Rename the parser',
      );
      final stored = dao.getById(checkpoint!.id)!;
      expect(stored.reason, CheckpointReason.turnStart);
      expect(stored.turn, 4);
      expect(stored.prompt, 'Rename the parser');
      expect(stored.additions, 3);
      expect(stored.deletions, 1);
      // A binary file has no count, and says so rather than reading as zero.
      expect(stored.lineStats.containsKey('lib/b.dart'), isFalse);
      expect(dao.lastTurn('s1'), 4);
    });
  });
}
