import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// The workspace domain at the server — contexts, projects, checkouts and
/// saved sections: the rules it applies to each write, and what every client
/// is told.
void main() {
  late AppDatabase db;
  late DataService service;
  late DataSession app;
  late List<DataChanges> told;
  final now = DateTime.utc(2026, 9, 26, 12);
  var ids = 0;

  const win = EnvironmentPath(environmentId: 'windows', path: r'C:\src\demo');
  const wsl = EnvironmentPath(environmentId: 'wsl', path: '/home/me/demo');

  setUp(() {
    db = AppDatabase.memory();
    ids = 0;
    service = DataService(db, clock: () => now, newId: () => 'id${++ids}');
    app = service.open((_) {});
    told = [];
    service.open(told.add).handle(const DataSubscribe());
    for (final (id, kind) in [('windows', 'windowsNative'), ('wsl', 'wsl')]) {
      db.execute(
        'INSERT INTO execution_environments (id, kind, name, created_at) '
        "VALUES (?, ?, ?, '2026-01-01T00:00:00.000Z');",
        [id, kind, id],
      );
    }
  });
  tearDown(() => db.close());

  Matcher refused(DataRefusalCode code, [String? words]) => throwsA(
    isA<DataRefused>()
        .having((r) => r.code, 'code', code)
        .having((r) => r.message, 'message', contains(words ?? '')),
  );

  DiscoveredRepository found(String name, EnvironmentPath path) =>
      DiscoveredRepository(name: name, path: path);

  EnvironmentPath under(EnvironmentPath root, String child) => EnvironmentPath(
    environmentId: root.environmentId,
    path: root.environmentId == 'windows'
        ? '${root.path}\\$child'
        : '${root.path}/$child',
  );

  ProjectCheckouts create({
    String name = 'Demo',
    EnvironmentPath root = win,
    List<DiscoveredRepository> found = const [],
    String? workspaceId,
  }) => app
      .handle(
        ProjectCreate(
          projectName: name,
          root: root,
          found: found,
          workspaceId: workspaceId,
        ),
      )
      .value;

  WorkspaceSnapshot snapshot() => app.handle(const WorkspaceList()).value;

  group('contexts', () {
    test('a new one is stamped by the server; names are trimmed', () {
      final made = app
          .handle(
            const WorkspacePut(
              id: 'w1',
              workspaceName: '  PopupBits ',
              description: '  ',
            ),
          )
          .value;
      expect(made.name, 'PopupBits');
      expect(made.description, isNull);
      expect(made.createdAt, now);
      expect(snapshot().workspaces, [made]);
      expect((told.single.changes.single as WorkspaceChanged).workspace, made);
    });

    test('a blank name and one a picker could not tell apart are refused', () {
      expect(
        () => app.handle(const WorkspacePut(id: 'w1', workspaceName: ' ')),
        refused(DataRefusalCode.invalid, 'needs a name'),
      );
      app.handle(const WorkspacePut(id: 'w1', workspaceName: 'Games'));
      expect(
        () => app.handle(const WorkspacePut(id: 'w2', workspaceName: 'games')),
        refused(DataRefusalCode.invalid, 'already exists'),
      );
      // Renaming a context to its own name, differently cased, is not a clash.
      final renamed = app
          .handle(const WorkspacePut(id: 'w1', workspaceName: 'GAMES'))
          .value;
      expect(renamed.name, 'GAMES');
      expect(renamed.createdAt, now);
    });

    test('ordered by name, ignoring case', () {
      for (final (id, name) in [('a', 'personal'), ('b', 'Appwrite')]) {
        app.handle(WorkspacePut(id: id, workspaceName: name));
      }
      expect(
        [for (final w in snapshot().workspaces) w.name],
        ['Appwrite', 'personal'],
      );
    });

    test('a colour is kept as its word, and cleared', () {
      app.handle(const WorkspacePut(id: 'w1', workspaceName: 'W'));
      expect(
        app
            .handle(const WorkspaceSetColor(id: 'w1', color: 'teal'))
            .value
            .color,
        'teal',
      );
      expect(app.handle(const WorkspaceSetColor(id: 'w1')).value.color, isNull);
      expect(
        () => app.handle(const WorkspaceSetColor(id: 'nope')),
        refused(DataRefusalCode.notFound),
      );
    });

    test('deleting one keeps its projects, unassigned, and says so', () {
      app.handle(const WorkspacePut(id: 'w1', workspaceName: 'W'));
      final project = create(workspaceId: 'w1').project;
      told.clear();

      final reply = app.handle(const WorkspaceDelete('w1'));

      expect(snapshot().workspaces, isEmpty);
      expect(snapshot().projects.single.workspaceId, isNull);
      expect(snapshot().projects.single.name, project.name);
      for (final changes in [reply.changes, told.single.changes]) {
        expect(changes.first, isA<WorkspaceRemoved>());
        expect((changes.last as ProjectChanged).project.workspaceId, isNull);
      }
    });

    test('filing projects moves them in one write, and unfiles them', () {
      app.handle(const WorkspacePut(id: 'w1', workspaceName: 'W'));
      final a = create(name: 'A').project;
      final b = create(name: 'B', root: wsl).project;

      app.handle(ProjectsFile({a.id: 'w1', b.id: 'w1'}));
      expect(
        [for (final p in snapshot().projects) p.workspaceId],
        ['w1', 'w1'],
      );
      app.handle(ProjectsFile({a.id: null}));
      expect(snapshot().projects.first.workspaceId, isNull);
      expect(
        () => app.handle(ProjectsFile({a.id: 'nope'})),
        refused(DataRefusalCode.notFound),
      );
    });
  });

  group('creating a project', () {
    test('records what discovery found as its checkouts', () {
      final made = create(
        found: [
          found('app', under(win, 'app')),
          found('api', under(win, 'api')),
        ],
      );
      expect(made.project.createdAt, now);
      expect([for (final r in made.repositories) r.name], ['app', 'api']);
      expect(
        made.repositories.every((r) => r.projectId == made.project.id),
        isTrue,
      );
      expect(snapshot().repositories, made.repositories);
      expect(told.single.changes, hasLength(3));
    });

    test('a folder that is not a clone is still somewhere to run', () {
      final made = create(root: wsl);
      expect(made.repositories.single.path, wsl);
      expect(made.repositories.single.name, 'Demo');
    });

    test('a blank name, an unknown environment or context is refused', () {
      expect(() => create(name: ' '), refused(DataRefusalCode.invalid));
      expect(
        () => create(
          root: const EnvironmentPath(environmentId: 'ssh:gone', path: '/x'),
        ),
        refused(DataRefusalCode.notFound),
      );
      expect(
        () => create(workspaceId: 'nope'),
        refused(DataRefusalCode.notFound),
      );
      expect(snapshot().projects, isEmpty);
    });
  });

  group('editing a project', () {
    test('a rename touches nothing else; a blank one is refused', () {
      final made = create();
      final updated = app
          .handle(ProjectUpdate(id: made.project.id, projectName: ' Renamed '))
          .value;
      expect(updated.project.name, 'Renamed');
      expect(updated.project.root, win);
      expect(updated.rebased, isEmpty);
      expect(
        () => app.handle(ProjectUpdate(id: made.project.id, projectName: '')),
        refused(DataRefusalCode.invalid),
      );
    });

    test('a moved root carries the checkouts under it, keeping their ids', () {
      final made = create(found: [found('app', under(win, 'app'))]);
      final outside = app
          .handle(
            CheckoutsAdd(
              projectId: made.project.id,
              found: [
                found(
                  'far',
                  const EnvironmentPath(
                    environmentId: 'windows',
                    path: r'D:\far',
                  ),
                ),
              ],
            ),
          )
          .value
          .single;
      const moved = EnvironmentPath(environmentId: 'windows', path: r'E:\demo');

      final updated = app
          .handle(
            ProjectUpdate(
              id: made.project.id,
              root: moved,
              found: [
                found('app', under(moved, 'app')),
                found('new', under(moved, 'new')),
              ],
            ),
          )
          .value;

      expect(updated.project.root, moved);
      expect(updated.rebased.single.id, made.repositories.single.id);
      expect(updated.rebased.single.path, under(moved, 'app'));
      expect(updated.leftBehind.single.id, outside.id);
      expect([for (final r in updated.discovered) r.name], ['new']);
      expect(snapshot().repositories, hasLength(3));
    });

    test('a move between environments carries the root checkout across', () {
      final made = create();
      final updated = app
          .handle(ProjectUpdate(id: made.project.id, root: wsl))
          .value;
      expect(updated.rebased.single.path, wsl);
      expect(updated.rebased.single.id, made.repositories.single.id);
    });

    test('the same root spelled differently is not a move', () {
      final made = create();
      final updated = app
          .handle(
            ProjectUpdate(
              id: made.project.id,
              root: const EnvironmentPath(
                environmentId: 'windows',
                path: r'c:\SRC\demo\',
              ),
            ),
          )
          .value;
      expect(updated.rebased, isEmpty);
      expect(snapshot().repositories.single.path, win);
    });

    test('the default checkout must be one of its own', () {
      final made = create();
      final other = create(name: 'Other', root: wsl);
      final own = made.repositories.single.id;
      Project update(ProjectUpdate request) =>
          app.handle(request).value.project;

      expect(
        update(
          ProjectUpdate(id: made.project.id, defaultRepositoryId: own),
        ).defaultRepositoryId,
        own,
      );
      expect(
        update(
          ProjectUpdate(id: made.project.id, projectName: 'Kept'),
        ).defaultRepositoryId,
        own,
      );
      expect(
        update(
          ProjectUpdate(
            id: made.project.id,
            defaultRepositoryId: other.repositories.single.id,
          ),
        ).defaultRepositoryId,
        isNull,
      );
      update(ProjectUpdate(id: made.project.id, defaultRepositoryId: own));
      expect(
        update(
          ProjectUpdate(id: made.project.id, clearDefaultRepository: true),
        ).defaultRepositoryId,
        isNull,
      );
    });
  });

  group('deleting a project', () {
    test(
      'is one operation: its checkouts go, its notes and todos stay unfiled, '
      'and every client is told',
      () {
        final made = create();
        app.handle(NoteCapture(id: 'n', body: 'x', projectId: made.project.id));
        app.handle(TodoAdd(id: 't', body: 'y', projectId: made.project.id));
        told.clear();

        final reply = app.handle(ProjectDelete(made.project.id));

        expect(snapshot().projects, isEmpty);
        expect(snapshot().repositories, isEmpty);
        expect(app.handle(const NotesList()).value.single.projectId, isNull);
        expect(app.handle(const TodosList()).value.single.projectId, isNull);
        for (final changes in [reply.changes, told.single.changes]) {
          expect(
            changes.whereType<ProjectRemoved>().single.id,
            made.project.id,
          );
          expect(changes.whereType<RepositoryRemoved>(), hasLength(1));
          expect(
            changes.whereType<NoteChanged>().single.note.projectId,
            isNull,
          );
          expect(
            changes.whereType<TodoChanged>().single.todo.projectId,
            isNull,
          );
        }
        expect(
          () => app.handle(ProjectDelete(made.project.id)),
          refused(DataRefusalCode.notFound),
        );
      },
    );

    test('is refused while an ACP session of its runs, and goes once it '
        'has stopped', () {
      final made = create();
      db.execute('PRAGMA foreign_keys = OFF;');
      db.execute(
        'INSERT INTO sessions (id, repository_id, agent_installation_id, '
        'title, use_worktree, status, created_at) '
        'VALUES (?, ?, ?, ?, 0, ?, ?);',
        [
          's1',
          made.repositories.single.id,
          'a1',
          'Over ACP',
          'running',
          '$now',
        ],
      );
      db.execute('PRAGMA foreign_keys = ON;');
      var live = {'s1', 'elsewhere'};
      service.liveAcpSessions = () => live;

      expect(
        () => app.handle(ProjectDelete(made.project.id)),
        refused(DataRefusalCode.invalid, '1 ACP session running'),
      );
      expect(snapshot().projects, hasLength(1));

      live = {'elsewhere'};
      app.handle(ProjectDelete(made.project.id));
      expect(snapshot().projects, isEmpty);
    });
  });

  group('checkouts', () {
    test('a rescan adds only what is not recorded, however it is spelled', () {
      final made = create(found: [found('app', under(win, 'app'))]);
      final added = app
          .handle(
            CheckoutsAdd(
              projectId: made.project.id,
              found: [
                found(
                  'app',
                  const EnvironmentPath(
                    environmentId: 'windows',
                    path: r'c:\src\DEMO\app\',
                  ),
                ),
                found('api', under(win, 'api')),
              ],
            ),
          )
          .value;
      expect([for (final r in added) r.name], ['api']);
    });

    test('a project with nowhere to run gets its own folder, once', () {
      final made = create();
      app.handle(CheckoutsRetire([made.repositories.single.id]));
      expect(snapshot().repositories, isEmpty);

      final added = app.handle(CheckoutsAdd(projectId: made.project.id)).value;
      expect(added.single.path, win);
      expect(
        app.handle(CheckoutsAdd(projectId: made.project.id)).value,
        isEmpty,
      );
      expect(
        app
            .handle(CheckoutsAdd(projectId: made.project.id, orRoot: false))
            .value,
        isEmpty,
      );
    });

    test('retiring deletes only what no history points at', () {
      final made = create(
        found: [found('a', under(win, 'a')), found('b', under(win, 'b'))],
      );
      final [kept, gone] = made.repositories;
      app.handle(
        ProjectUpdate(id: made.project.id, defaultRepositoryId: gone.id),
      );
      db.execute(
        'INSERT INTO imported_sessions (id, repository_id, source, external_id, '
        'environment_id, preview, file_path, store_home, is_subagent, created_at) '
        "VALUES ('i', ?, 'claude-code', 'x', 'windows', 'p', 'f', 'h', 0, 'now');",
        [kept.id],
      );
      told.clear();

      final records = app
          .handle(CheckoutsRetire([kept.id, gone.id, 'unknown']))
          .value;

      expect(records, {kept.id: 1, gone.id: 0});
      expect(snapshot().repositories, [kept]);
      final changes = told.single.changes;
      expect(changes.whereType<RepositoryRemoved>().single.id, gone.id);
      // The default went with it (`ON DELETE SET NULL`), and that is told too.
      expect(
        changes.whereType<ProjectChanged>().single.project.defaultRepositoryId,
        isNull,
      );
    });

    test('identity is recorded on every row at that location, and cleared', () {
      final made = create();
      final other = create(name: 'Other', found: [found('same', win)]);
      final changed = app
          .handle(
            const CheckoutsIdentify(
              path: EnvironmentPath(
                environmentId: 'windows',
                path: r'c:\SRC\demo',
              ),
              canonicalId: 'github.com/a/b',
            ),
          )
          .value;
      expect(
        {for (final r in changed) r.id},
        {made.repositories.single.id, other.repositories.single.id},
      );
      expect(
        app
            .handle(
              const CheckoutsIdentify(path: win, canonicalId: 'github.com/a/b'),
            )
            .value,
        isEmpty,
        reason: 'nothing to change is no write',
      );
      final cleared = app.handle(const CheckoutsIdentify(path: win)).value;
      expect(cleared.every((r) => r.canonicalId == null), isTrue);
      // A rename of the project leaves it alone.
      app.handle(ProjectUpdate(id: made.project.id, projectName: 'Renamed'));
      expect(snapshot().repositories.first.canonicalId, isNull);
    });

    test('the projects keeping an environment are named', () {
      create(name: 'Rooted', root: wsl);
      create(name: 'Mixed', found: [found('w', under(wsl, 'w'))]);
      create(name: 'Elsewhere');
      expect(app.handle(const ProjectsUsingEnvironment('wsl')).value, [
        'Mixed',
        'Rooted',
      ]);
    });
  });

  group('sections', () {
    test('a manual section keeps its members; a rule section keeps none', () {
      final manual = app
          .handle(
            const SectionPut(
              StoredSection(
                id: 'm',
                name: ' Mine ',
                kind: 'manual',
                position: 9,
                members: {'s1', 's2'},
              ),
            ),
          )
          .value;
      expect(manual.name, 'Mine');
      expect(manual.members, {'s1', 's2'});
      final rule = app
          .handle(
            const SectionPut(
              StoredSection(
                id: 'r',
                name: 'Release',
                kind: 'branchGlob',
                pattern: 'release/*',
                position: 10,
                members: {'s1'},
              ),
            ),
          )
          .value;
      expect(rule.members, isEmpty);
      expect(rule.pattern, 'release/*');
      expect(told.last.changes.single, isA<SectionChanged>());
    });

    test('the built-in Pinned section only folds', () {
      final pinned = snapshot().sections.firstWhere((s) => s.kind == 'pinned');
      expect(
        app
            .handle(SectionPut(pinned.copyWith(collapsed: !pinned.collapsed)))
            .value
            .collapsed,
        !pinned.collapsed,
      );
      expect(
        () => app.handle(SectionPut(pinned.copyWith(name: 'Mine'))),
        refused(DataRefusalCode.reserved),
      );
      expect(
        () => app.handle(SectionDelete(pinned.id)),
        refused(DataRefusalCode.reserved),
      );
      expect(
        () => app.handle(
          const SectionPut(
            StoredSection(id: 'p2', name: 'P', kind: 'pinned', position: 5),
          ),
        ),
        refused(DataRefusalCode.reserved),
      );
    });

    test('reorder renumbers, telling only what moved; delete removes', () {
      final before = snapshot().sections;
      final ids = [
        before.first.id,
        before.last.id,
        ...before.skip(1).take(before.length - 2).map((s) => s.id),
      ];
      final after = app.handle(SectionsReorder(ids)).value;
      expect([for (final s in after) s.id], ids);
      expect(told.last.changes, isNotEmpty);

      app.handle(SectionDelete(before.last.id));
      expect(snapshot().sections, hasLength(before.length - 1));
      expect(
        () => app.handle(const SectionDelete('nope')),
        refused(DataRefusalCode.notFound),
      );
    });
  });
}
