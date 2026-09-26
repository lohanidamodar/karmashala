import 'package:agent_cli/process.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_checkpoints/store.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// The rules a client's copy answers with, against the store's own queries
/// over the same rows.
void main() {
  late AppDatabase db;
  late CheckpointDao dao;
  const a = EnvironmentPath(environmentId: 'windows', path: r'C:\a');
  const b = EnvironmentPath(environmentId: 'wsl:Ubuntu', path: '/home/b');
  var n = 0;

  Checkpoint make(EnvironmentPath repo, {int? turn}) => Checkpoint(
    id: 'c${++n}',
    sessionId: 's1',
    repository: repo,
    sequence: 0,
    treeSha: 't$n',
    commitSha: 'k$n',
    parentCommitSha: null,
    headSha: null,
    reason: CheckpointReason.turn,
    createdAt: DateTime.utc(2026, 9, 1, n),
    turn: turn,
    files: const [
      FileChange(
        path: 'lib/x.dart',
        type: FileChangeType.modified,
        staged: false,
        unstaged: true,
      ),
    ],
    lineStats: const {'lib/x.dart': FileDiffStat(added: 2, removed: 1)},
  );

  setUp(() {
    db = AppDatabase.memory()..execute('PRAGMA foreign_keys = OFF;');
    dao = CheckpointDao(db);
    n = 0;
    for (final (repo, turn) in [(a, 1), (b, 1), (a, 2), (b, null), (a, 3)]) {
      dao.insert(make(repo, turn: turn));
    }
  });
  tearDown(() => db.close());

  test('the copy answers what the store answers', () {
    final session = dao.forSession('s1');
    expect(latestCheckpointIn(session)!.id, dao.latestFor('s1')!.id);
    expect(
      latestCheckpointIn(session, repository: b)!.id,
      dao.latestFor('s1', repository: b)!.id,
    );
    for (final c in session) {
      expect(previousCheckpointIn(session, c)?.id, dao.previousOf(c)?.id);
    }
    expect(lastCheckpointTurnIn(session), dao.lastTurn('s1'));
    expect(checkpointRepositoriesIn(session), dao.repositoriesFor('s1'));
    expect(
      checkpointChainIn(session, a).map((c) => c.id),
      dao.forRepository('s1', a).map((c) => c.id),
    );
    expect(nextCheckpointSequence(session), 6);
  });

  test('a checkpoint crosses as JSON unchanged', () {
    final stored = dao.getById('c1')!;
    final back = checkpointFromJson(checkpointToJson(stored));
    expect(back.id, stored.id);
    expect(back.repository, stored.repository);
    expect(back.sequence, stored.sequence);
    expect(back.turn, 1);
    expect(back.files.single.path, 'lib/x.dart');
    expect(back.files.single.type, FileChangeType.modified);
    expect(back.additions, 2);
    expect(back.deletions, 1);
    expect(back.createdAt, stored.createdAt);
    expect(() => checkpointFromJson({'id': 1}), throwsFormatException);
  });

  test('a recorded checkpoint joins the list in sequence order', () {
    final session = dao.forSession('s1');
    final relabelled = session[1].copyWith(label: 'kept');
    final after = withCheckpoint(session, relabelled);
    expect(after.map((c) => c.id), session.map((c) => c.id));
    expect(after[1].label, 'kept');
  });
}
