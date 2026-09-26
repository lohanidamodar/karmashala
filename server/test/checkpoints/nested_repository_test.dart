import 'dart:io';
import 'dart:math';

import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'checkpoint_fixtures.dart';

/// The owner's layout, in real git: a session started in a workspace folder
/// whose projects are nested clones the workspace's `.gitignore` hides. Every
/// edit lands in a clone, so the clone the tool names is checkpointed — and a
/// repository outside the session's folders never is.
void main() {
  late CheckpointWorld w;

  setUp(() async => w = await CheckpointWorld.create());
  tearDown(() => w.close());

  test('an edit in a nested, ignored clone is checkpointed before and after, '
      'and undone by its before-turn checkpoint', () async {
    final file = p.join(w.app, 'main.txt');
    await w.hook('UserPromptSubmit', {'prompt': 'Change the app'});
    await w.hook('PreToolUse', w.edit(file));
    await w.settle();
    File(file).writeAsStringSync('one\nTWO\nthree\n');
    await w.hook('Stop');
    await w.untilCheckpoints(w.app, 2);

    final nested = w.ofRepo(w.app);
    expect(
      [for (final c in nested) c.reason],
      [CheckpointReason.turnStart, CheckpointReason.turn],
    );
    expect(nested.first.files, isEmpty, reason: 'taken before the edit');
    expect(nested.last.files.map((f) => f.path), ['main.txt']);
    expect(nested.last.additions, 2);
    expect(nested.last.deletions, 1);
    expect(nested.last.turn, 1);
    expect(nested.last.prompt, 'Change the app');

    final undone = await w.ask(CheckpointRestore(nested.first.id));
    expect(undone.outcomeOrThrow.alreadyThere, isFalse);
    expect(File(file).readAsStringSync(), 'one\ntwo\n');
  }, skip: hasGit ? false : 'git is not on PATH');

  test('a relative path is read from where the agent says it works', () async {
    await w.hook('UserPromptSubmit', {
      'prompt': 'Change the app',
      'cwd': w.app,
    });
    await w.hook('PreToolUse', {'cwd': w.app, ...w.edit('main.txt')});
    await w.settle();
    expect(w.ofRepo(w.app), hasLength(1), reason: 'the clone, by its cwd');
  }, skip: hasGit ? false : 'git is not on PATH');

  test(
    'a repository outside the session folders is not checkpointed',
    () async {
      final elsewhere = Directory.systemTemp.createTempSync('karmashala_out_');
      addTearDown(() => elsewhere.deleteSync(recursive: true));
      final outside = elsewhere.resolveSymbolicLinksSync();
      File(p.join(outside, 'notes.txt')).writeAsStringSync('x\n');
      git(outside, ['init', '-q']);

      await w.hook('UserPromptSubmit', {'prompt': 'Read something'});
      await w.hook('PreToolUse', {
        'tool_name': 'Read',
        'tool_input': {'file_path': p.join(outside, 'notes.txt')},
      });
      await w.hook('Stop');
      await w.untilCheckpoints(w.hub, 1);
      await w.settle();

      expect(w.ofRepo(outside), isEmpty);
      expect(w.ofRepo(w.hub), hasLength(1), reason: 'its own checkout, once');
    },
    skip: hasGit ? false : 'git is not on PATH',
  );

  test('a checkpointed repository whose directory is gone is not tried '
      'again', () async {
    final worktree = p.join(w.hub, 'projects', 'gone');
    Directory(worktree).createSync(recursive: true);
    File(p.join(worktree, 'a.txt')).writeAsStringSync('a\n');
    git(worktree, ['init', '-q']);
    git(worktree, ['add', '-A']);
    git(worktree, ['commit', '-q', '-m', 'gone']);
    final gone = w.local(worktree);
    File(p.join(worktree, 'a.txt')).writeAsStringSync('b\n');
    expect(
      await w.checkpoints.service.capture(gone, sessionId: 's1'),
      isNotNull,
    );
    Directory(worktree).deleteSync(recursive: true);

    await w.hook('UserPromptSubmit', {'prompt': 'Carry on'});
    await w.hook('Stop');
    await w.untilCheckpoints(w.hub, 1);
    await w.settle();

    expect(
      (await w.ask(const CheckpointSkips()))['s1'] ?? '',
      isNot(contains('failed')),
    );
    // History is kept: forgetting where to look is not deleting what was seen.
    expect(w.ofRepo(worktree), hasLength(1));
  }, skip: hasGit ? false : 'git is not on PATH');

  test('pruning leaves a chain git holds, of only the kept trees', () async {
    final service = w.checkpoints.service;
    final repo = w.local(w.app);
    for (var i = 0; i < 3; i++) {
      File(p.join(w.app, 'main.txt')).writeAsStringSync('v$i\n');
      expect(await service.capture(repo, sessionId: 's1'), isNotNull);
    }
    expect(await service.prune(repo, sessionId: 's1', keep: 1), 2);

    final kept = checkpointChainIn(w.rows(), repo).single;
    final count = Process.runSync('git', [
      '-C',
      w.app,
      'rev-list',
      '--count',
      Checkpoint.refFor('s1'),
    ]);
    expect((count.stdout as String).trim(), '1');
    File(
      p.join(w.app, 'main.txt'),
    ).writeAsStringSync('later ${Random().nextInt(9)}\n');
    final back = await w.ask(CheckpointRestore(kept.id, confirm: true));
    expect(back.outcomeOrThrow.files.single.path, 'main.txt');
    expect(File(p.join(w.app, 'main.txt')).readAsStringSync(), 'v2\n');
  }, skip: hasGit ? false : 'git is not on PATH');
}
