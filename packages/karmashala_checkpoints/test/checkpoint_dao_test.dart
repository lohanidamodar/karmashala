import 'package:agent_cli/process.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_checkpoints/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

void main() {
  final at = DateTime.utc(2026, 9, 25, 10);
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.memory();
    db.execute('PRAGMA foreign_keys = OFF;');
  });
  tearDown(() => db.close());

  Checkpoint base(String id, {required String runId}) => Checkpoint(
    id: id,
    sessionId: runId,
    repository: const EnvironmentPath(environmentId: 'local', path: '/src'),
    sequence: 0,
    treeSha: 'tree-$id',
    commitSha: 'commit-$id',
    parentCommitSha: null,
    headSha: 'head',
    reason: CheckpointReason.manual,
    createdAt: at,
    label: 'before automation "Nightly"',
  );

  test('an automation run\'s base is numbered and read back by id', () {
    final dao = CheckpointDao(db);
    final first = dao.insert(base('cp1', runId: 'run1'));
    final second = dao.insert(base('cp2', runId: 'run1'));
    expect(second.sequence, first.sequence + 1);
    final read = dao.getById('cp1')!;
    expect(read.reason, CheckpointReason.manual);
    expect(read.label, 'before automation "Nightly"');
    expect(read.repository.path, '/src');
    expect(dao.forSession('run1').map((c) => c.id), ['cp1', 'cp2']);
  });
}
