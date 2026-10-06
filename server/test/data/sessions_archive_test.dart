import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// **Archiving a session hides it, and nothing else.** The server owns the
/// flag: `sessions.archive` and `sessions.unarchive` take one id or many, act
/// on the ended ones and their ended descendants, leave a live one alone and
/// name it, and tell the whole act as one batch. The worktree is never
/// touched.
void main() {
  late AppDatabase db;
  late DataService service;
  late DataSession app;
  late List<DataChanges> told;
  final now = DateTime.utc(2026, 10, 6, 12);
  var running = <String>{};

  void seedWorkspace() {
    const at = '2026-01-01T00:00:00.000Z';
    db.execute(
      'INSERT INTO execution_environments (id, kind, name, created_at) '
      "VALUES ('windows', 'windowsNative', 'Windows', ?);",
      [at],
    );
    db.execute(
      'INSERT INTO projects (id, name, root_environment_id, root_path, '
      "created_at) VALUES ('p1', 'Demo', 'windows', 'C:\\src\\p1', ?);",
      [at],
    );
    db.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      "created_at) VALUES ('r1', 'p1', 'r1', 'windows', 'C:\\src\\r1', ?);",
      [at],
    );
    db.execute(
      'INSERT INTO agent_installations '
      '(id, agent_kind, environment_id, executable_path, created_at) '
      "VALUES ('a1', 'claude-code', 'windows', 'claude', ?);",
      [at],
    );
  }

  const tree = EnvironmentPath(environmentId: 'windows', path: r'C:\wt\s');

  void add(
    String id, {
    SessionStatus status = SessionStatus.completed,
    String? parent,
  }) => app.handle(
    SessionCreate(
      Session(
        id: id,
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Work $id',
        useWorktree: true,
        worktree: tree,
        status: status,
        createdAt: now,
        parentSessionId: parent,
      ),
    ),
  );

  Session rowOf(String id) => app
      .handle(const SessionsList())
      .value
      .sessions
      .singleWhere((s) => s.id == id);

  setUp(() {
    db = AppDatabase.memory();
    running = {};
    service = DataService(db, clock: () => now, runsSession: running.contains);
    app = service.open((_) {});
    told = [];
    service.open(told.add).handle(const DataSubscribe());
    seedWorkspace();
  });
  tearDown(() => db.close());

  group('sessions.archive', () {
    test('archives ended sessions in one batch and keeps their worktree', () {
      add('s1');
      add('s2', status: SessionStatus.failed);
      add('s3', status: SessionStatus.unknown);
      told.clear();

      final result = app
          .handle(const SessionsArchive(['s1', 's2', 's3']))
          .value;

      expect(result.changed, ['s1', 's2', 's3']);
      expect(result.live, isEmpty);
      expect(told, hasLength(1), reason: 'one batch for the whole act');
      expect(
        told.single.changes.whereType<SessionRowChanged>().map(
          (c) => c.session.id,
        ),
        ['s1', 's2', 's3'],
      );
      for (final id in ['s1', 's2', 's3']) {
        final row = rowOf(id);
        expect(row.archivedAt, now);
        expect(row.worktree, tree, reason: 'archiving never touches it');
        expect(row.worktreeRemovedAt, isNull);
      }
    });

    test('a live session is left alone and named, with why', () {
      add('busy', status: SessionStatus.running);
      add('held', status: SessionStatus.unknown);
      running.add('held');
      add('done');
      told.clear();

      final result = app
          .handle(const SessionsArchive(['busy', 'held', 'done']))
          .value;

      expect(result.changed, ['done']);
      expect(result.live.map((s) => s.id), ['busy', 'held']);
      expect(result.live.first.title, 'Work busy');
      expect(rowOf('busy').isArchived, isFalse);
      expect(rowOf('held').isArchived, isFalse);
      expect(rowOf('done').isArchived, isTrue);
    });

    test('cascades to ended descendants; live ones stay and are named', () {
      add('parent');
      add('child', parent: 'parent');
      add('grandchild', parent: 'child');
      add('liveChild', parent: 'parent', status: SessionStatus.idle);
      add('other');
      told.clear();

      final result = app.handle(const SessionsArchive(['parent'])).value;

      expect(result.changed, ['parent', 'child', 'grandchild']);
      expect(result.live.map((s) => s.id), ['liveChild']);
      expect(rowOf('liveChild').isArchived, isFalse);
      expect(rowOf('other').isArchived, isFalse);
      expect(told, hasLength(1));
    });

    test('an archived or unknown id is skipped quietly, and nothing to do '
        'tells nothing', () {
      add('s1');
      app.handle(const SessionsArchive(['s1']));
      told.clear();

      final result = app
          .handle(const SessionsArchive(['s1', 'never']))
          .value;

      expect(result.changed, isEmpty);
      expect(result.missing, ['never']);
      expect(told, isEmpty);
    });
  });

  group('sessions.unarchive', () {
    test('restores the sessions and their archived descendants, one batch', () {
      add('parent');
      add('child', parent: 'parent');
      add('s2');
      app.handle(const SessionsArchive(['parent', 's2']));
      told.clear();

      final result = app
          .handle(const SessionsUnarchive(['parent', 's2']))
          .value;

      expect(result.changed, ['parent', 'child', 's2']);
      expect(told, hasLength(1));
      for (final id in ['parent', 'child', 's2']) {
        expect(rowOf(id).isArchived, isFalse);
        expect(rowOf(id).worktree, tree);
      }
    });

    test('a removed worktree stays removed when its session is restored', () {
      add('s1');
      final at = now.subtract(const Duration(days: 2));
      app.handle(SessionEdit('s1', SessionPatch.removeWorktree(at)));
      expect(rowOf('s1').isArchived, isTrue);

      app.handle(const SessionsUnarchive(['s1']));

      expect(rowOf('s1').isArchived, isFalse);
      expect(rowOf('s1').worktreeRemovedAt, at);
    });
  });
}
