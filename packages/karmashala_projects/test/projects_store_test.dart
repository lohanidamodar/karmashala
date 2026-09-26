import 'package:agent_cli/process.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// The workspace tables as the server reads and writes them, and the orders
/// a client's copy must read in.
void main() {
  final t0 = DateTime.utc(2026, 9, 26, 12);
  const root = EnvironmentPath(environmentId: 'windows', path: r'C:\src\demo');
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.memory();
    db.execute(
      'INSERT INTO execution_environments (id, kind, name, created_at) '
      "VALUES ('windows', 'windowsNative', 'Windows', '2026-01-01T00:00:00Z');",
    );
  });
  tearDown(() => db.close());

  Project project(String id, {DateTime? at, String? workspaceId}) => Project(
    id: id,
    name: id,
    root: root,
    createdAt: at ?? t0,
    workspaceId: workspaceId,
  );

  Repository checkout(String id, String projectId, {String path = r'C:\x'}) =>
      Repository(
        id: id,
        projectId: projectId,
        name: id,
        path: EnvironmentPath(environmentId: 'windows', path: path),
        createdAt: t0,
      );

  test('projects and checkouts round-trip, in the order a copy sorts', () {
    final projects = ProjectDao(db)
      ..insert(project('b', at: t0.add(const Duration(minutes: 1))))
      ..insert(project('a'));
    final repositories = RepositoryDao(db)
      ..insert(checkout('r2', 'a', path: r'C:\src\demo\api'))
      ..insert(checkout('r1', 'a', path: r'C:\src\demo\app'));

    final all = projects.getAll();
    expect([for (final p in all) p.id], ['a', 'b']);
    expect([...all]..sort(compareProjects), all);
    expect(repositories.getByProject('a').map((r) => r.id), ['r1', 'r2']);
    expect(
      repositories.getByLocation(
        const EnvironmentPath(
          environmentId: 'windows',
          path: r'c:\SRC\demo\app\',
        ),
      ),
      [checkout('r1', 'a', path: r'C:\src\demo\app')],
    );

    // Deleting a project takes its checkouts with it.
    projects.delete('a');
    expect(repositories.getAll(), isEmpty);
  });

  test('a context outlives nothing: its projects stay, unassigned', () {
    WorkspaceDao(db).insert(Workspace(id: 'w', name: 'W', createdAt: t0));
    ProjectDao(db).insert(project('p', workspaceId: 'w'));
    expect(ProjectDao(db).inWorkspace('w').single.id, 'p');

    WorkspaceDao(db).delete('w');
    expect(ProjectDao(db).getById('p')!.workspaceId, isNull);
  });

  test('contexts read by name, ignoring case, like compareWorkspaces', () {
    final dao = WorkspaceDao(db);
    for (final (id, name) in [
      ('1', 'personal'),
      ('2', 'Appwrite'),
      ('3', 'game'),
    ]) {
      dao.insert(Workspace(id: id, name: name, createdAt: t0));
    }
    final all = dao.getAll();
    expect([for (final w in all) w.name], ['Appwrite', 'game', 'personal']);
    expect([...all]..sort(compareWorkspaces), all);
  });

  test('history keeps a checkout: every table that cascades is counted', () {
    ProjectDao(db).insert(project('p'));
    RepositoryDao(db).insert(checkout('r', 'p'));
    expect(RepositoryDao(db).historyReferenceCount('r'), 0);
    db.execute(
      'INSERT INTO imported_sessions (id, repository_id, source, external_id, '
      'environment_id, preview, file_path, store_home, is_subagent, created_at) '
      "VALUES ('i', 'r', 'claude-code', 'x', 'windows', 'p', 'f', 'h', 0, 't');",
    );
    db.execute(
      'INSERT INTO fanout_comparisons '
      '(id, repository_id, prompt, created_at, outcome, archived) '
      "VALUES ('f', 'r', 'try', '2026-01-02', 'merged', 0);",
    );
    expect(RepositoryDao(db).historyReferenceCount('r'), 2);
  });

  test('sections: seeded, written whole, members only for a manual one', () {
    final dao = SectionDao(db);
    final seeded = dao.getAll();
    expect([for (final s in seeded) s.kind].first, StoredSection.pinnedKind);
    expect(seeded.every((s) => s.collapsed), isTrue);
    expect([...seeded]..sort(compareSections), seeded);

    dao.put(
      const StoredSection(
        id: 'm',
        name: 'Mine',
        kind: 'manual',
        position: 9,
        members: {'a', 'b'},
      ),
    );
    dao.put(
      const StoredSection(
        id: 'g',
        name: 'Glob',
        kind: 'branchGlob',
        pattern: 'release/*',
        position: 10,
        members: {'a'},
      ),
    );
    expect(dao.getById('m')!.members, {'a', 'b'});
    expect(dao.getById('g')!.members, isEmpty);

    dao.put(dao.getById('m')!.copyWith(members: {'b'}, collapsed: false));
    expect(dao.getById('m')!.members, {'b'});
    expect(dao.getById('m')!.collapsed, isFalse);

    dao.reorder(['g', 'm']);
    expect(dao.getById('g')!.position, 0);
    dao.delete('m');
    expect(dao.getById('m'), isNull);
  });

  group('rules', () {
    String id() => 'n${DateTime.now().microsecondsSinceEpoch}';

    test('a new project with nothing found runs in its own folder', () {
      final p = project('p');
      expect(checkoutsForNewProject(p, const [], newId: id).single.path, root);
      const app = DiscoveredRepository(
        name: 'app',
        path: EnvironmentPath(
          environmentId: 'windows',
          path: r'C:\src\demo\app',
        ),
      );
      expect(
        checkoutsForNewProject(p, const [app], newId: id).single.name,
        'app',
      );
    });

    test('a rescan skips what is recorded, however it is spelled', () {
      final p = project('p');
      final added = checkoutsToAdd(
        p,
        [checkout('r', 'p', path: r'C:\src\demo\app')],
        const [
          DiscoveredRepository(
            name: 'app',
            path: EnvironmentPath(
              environmentId: 'windows',
              path: r'c:/SRC/demo/app/',
            ),
          ),
        ],
        newId: id,
        orRoot: true,
      );
      expect(added, isEmpty);
    });

    test('a moved root rebases what is under it, in the new spelling', () {
      final (:rebased, :leftBehind) = rebaseCheckouts(
        root,
        const EnvironmentPath(environmentId: 'wsl', path: '/home/me/demo'),
        [
          checkout('in', 'p', path: r'C:\src\demo\pkg\app'),
          checkout('root', 'p', path: r'C:\src\demo'),
          checkout('out', 'p', path: r'D:\elsewhere'),
        ],
      );
      expect(
        [for (final r in rebased) r.path.path],
        ['/home/me/demo/pkg/app', '/home/me/demo'],
      );
      expect(rebased.first.id, 'in');
      expect(leftBehind.single.id, 'out');
      expect(
        rootMoves(
          root,
          const EnvironmentPath(
            environmentId: 'windows',
            path: r'c:\SRC\demo\',
          ),
        ),
        isFalse,
      );
    });

    test('names are trimmed; blank is none', () {
      expect(rowNameOf('  a  '), 'a');
      expect(rowNameOf('   '), isNull);
      expect(descriptionOf(' '), isNull);
      expect(sameContextName('Games', 'gAMES'), isTrue);
    });

    test('values survive their wire shape', () {
      final w = Workspace(id: 'w', name: 'W', createdAt: t0, color: 'teal');
      final p = project('p', workspaceId: 'w');
      final r = checkout('r', 'p');
      expect(Workspace.fromJson(w.toJson()), w);
      expect(Project.fromJson(p.toJson()), p);
      expect(repositoryFromJson(repositoryToJson(r)), r);
      expect(() => Project.fromJson(const {'id': 1}), throwsFormatException);
    });
  });
}
