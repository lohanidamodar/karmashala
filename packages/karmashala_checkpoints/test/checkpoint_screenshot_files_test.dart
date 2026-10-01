import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_checkpoints/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final at = DateTime.utc(2026, 10, 1, 10);
  late AppDatabase db;
  late Directory root;

  setUp(() async {
    db = AppDatabase.memory();
    root = await Directory.systemTemp.createTemp('checkpoint_shots_');
  });
  tearDown(() async {
    db.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Checkpoint base(String id) => Checkpoint(
    id: id,
    sessionId: 's1',
    repository: const EnvironmentPath(environmentId: 'local', path: '/src'),
    sequence: 0,
    treeSha: 'tree-$id',
    commitSha: 'commit-$id',
    parentCommitSha: null,
    headSha: 'head',
    reason: CheckpointReason.manual,
    createdAt: at,
  );

  Future<File> shotOf(String checkpointId) async {
    final file = File(p.join(root.path, checkpointId, 'shot.png'));
    await file.create(recursive: true);
    CheckpointScreenshotDao(db).insert(
      CheckpointScreenshot(
        id: 'shot-$checkpointId',
        checkpointId: checkpointId,
        sessionId: 's1',
        source: CheckpointScreenshotSource.browser,
        size: 'compact',
        width: 1,
        height: 1,
        path: file.path,
        capturedAt: at,
      ),
    );
    return file;
  }

  Future<void> untilGone(Directory folder) async {
    for (var i = 0; i < 50 && await folder.exists(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('pruning a checkpoint deletes its screenshot folder', () async {
    final dao = CheckpointDao(db);
    dao.insert(base('cp1'));
    dao.insert(base('cp2'));
    final dropped = await shotOf('cp1');
    final kept = await shotOf('cp2');

    dao.prune(dropIds: ['cp1'], rewritten: const {});
    await untilGone(dropped.parent);

    expect(await dropped.parent.exists(), isFalse);
    expect(await kept.exists(), isTrue);
  });

  test('deleting a session deletes its checkpoints\' folders', () async {
    final dao = CheckpointDao(db);
    dao.insert(base('cp1'));
    final shot = await shotOf('cp1');

    dao.deleteForSession('s1');
    await untilGone(shot.parent);

    expect(await shot.parent.exists(), isFalse);
  });

  test('the sweep removes folders of checkpoints no longer recorded', () async {
    final dao = CheckpointDao(db);
    dao.insert(base('live'));
    await shotOf('live');
    await Directory(p.join(root.path, 'gone')).create();

    final removed = await sweepCheckpointScreenshotFolders(
      root.path,
      dao.exists,
    );

    expect(removed, 1);
    expect(await Directory(p.join(root.path, 'live')).exists(), isTrue);
    expect(await Directory(p.join(root.path, 'gone')).exists(), isFalse);
  });

  test('a sweep of a missing directory is a no-op', () async {
    expect(
      await sweepCheckpointScreenshotFolders(
        p.join(root.path, 'absent'),
        (_) => false,
      ),
      0,
    );
  });
}
