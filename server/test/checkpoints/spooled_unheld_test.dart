// Real git work: under a busy machine (several suites at once) it can pass
// the default 30 s, which is load, not a failure.
@Timeout.factor(4)
library;

import 'dart:io';

import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'checkpoint_fixtures.dart';

/// A hook a WSL agent spooled and the server drained (slice 5a): the agent
/// went on long before, so nothing can hold its tool, and the
/// before-turn snapshots that follow say so.
void main() {
  late CheckpointWorld w;

  setUp(() async => w = await CheckpointWorld.create());
  tearDown(() => w.close());

  /// Synchronous, like the real thing: there is nobody to answer.
  void spooled(String event, [Map<String, Object?> body = const {}]) =>
      w.checkpoints.spooled(w.hookEvent(event, body));

  test('a repository first named by a spooled tool is snapshotted after '
      'its edit, and the row says so', () async {
    final file = p.join(w.app, 'main.txt');
    const edited = 'one\nTWO\nthree\n';

    spooled('UserPromptSubmit', {'prompt': 'Change the app'});
    await w.untilCheckpoints(w.hub, 1);
    await w.settle();
    expect(w.ofRepo(w.app), isEmpty, reason: 'nothing has named it yet');

    spooled('PreToolUse', w.edit(file));
    // The agent already went on: the tool runs now.
    File(file).writeAsStringSync(edited);
    File(p.join(w.hub, 'README.md')).writeAsStringSync('hub\nchanged\n');

    spooled('Stop');
    await w.untilCheckpoints(w.hub, 2);
    await w.settle();

    final nested = w.ofRepo(w.app);
    expect([for (final c in nested) c.reason], [CheckpointReason.turnStart]);
    expect(blobIn(w.app, nested.single.treeSha, 'main.txt'), edited);
    expect(nested.single.label, lateTurnStartLabel(1));
    expect(
      checkpointTitle(nested.single),
      'Before: Change the app — may already include its first edit',
    );
    final before = w.ofRepo(w.hub).first;
    expect(before.reason, CheckpointReason.turnStart);
    expect(before.label, isNull, reason: 'returned before any tool');
    expect(blobIn(w.hub, before.treeSha, 'README.md'), 'hub\n');
  }, skip: hasGit ? false : 'git is not on PATH');

  test('a turn-start snapshot still running when a spooled tool arrives is '
      'marked, and the next turn does not inherit the mark', () async {
    spooled('UserPromptSubmit', {'prompt': 'Run the build'});
    spooled('PreToolUse', {
      'tool_name': 'Bash',
      'tool_input': {'command': 'make'},
    });
    await w.untilCheckpoints(w.hub, 1);
    await w.settle();
    File(p.join(w.hub, 'README.md')).writeAsStringSync('hub\nbuilt\n');
    spooled('Stop');
    await w.untilCheckpoints(w.hub, 2);
    await w.settle();
    expect(w.ofRepo(w.hub).first.reason, CheckpointReason.turnStart);
    expect(w.ofRepo(w.hub).first.label, lateTurnStartLabel(1));
    expect(
      w.log.where((l) => l.contains('answered before anything could hold it')),
      hasLength(1),
    );

    File(p.join(w.hub, 'README.md')).writeAsStringSync('hub\nby hand\n');
    spooled('UserPromptSubmit', {'prompt': 'Again'});
    await w.untilCheckpoints(w.hub, 3);
    await w.settle();
    final second = w.ofRepo(w.hub)[2];
    expect(second.reason, CheckpointReason.turnStart);
    expect(second.turn, 2);
    expect(second.label, isNull, reason: 'the mark belongs to turn 1');
  }, skip: hasGit ? false : 'git is not on PATH');

  test('the endpoint, when its hold is met, marks nothing: the warning is '
      'the spooled hook\'s, not every mid-turn snapshot\'s', () async {
    // A hold that is met however loaded the machine: the default 1.5 s can
    // expire under a full parallel suite, which is a different case.
    await w.close();
    w = await CheckpointWorld.create(hold: const Duration(seconds: 20));
    final file = p.join(w.app, 'main.txt');
    await w.hook('UserPromptSubmit', {'prompt': 'Change the app'});
    await w.hook('PreToolUse', w.edit(file));
    expect(w.log.where((l) => l.contains('released a tool')), isEmpty);
    File(file).writeAsStringSync('one\nTWO\n');
    await w.hook('Stop');
    await w.untilCheckpoints(w.app, 2, within: const Duration(seconds: 20));
    await w.settle();
    final nested = w.ofRepo(w.app);
    expect(blobIn(w.app, nested.first.treeSha, 'main.txt'), 'one\ntwo\n');
    expect(nested.first.label, isNull);
  }, skip: hasGit ? false : 'git is not on PATH');

  test('a spooled hook of no row here does nothing', () async {
    w.checkpoints.spooled(
      w.hookEvent('PreToolUse', w.edit('/tmp/x'), 'nobody'),
    );
    await w.settle();
    expect(w.rows(), isEmpty);
    expect(w.log, isEmpty);
  });
}
