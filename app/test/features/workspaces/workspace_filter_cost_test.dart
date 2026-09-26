import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala/src/features/workspaces/application/workspaces_controller.dart';
import 'package:karmashala/src/features/workspaces/domain/workspace_scope.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **What switching contexts costs, counted.**
///
/// The project list and `selectedProjectRepositoriesProvider` are hot paths
/// this app has already had to fix twice, and a scope filter is exactly the
/// kind of feature that quietly puts a query behind every row: ask each project
/// which workspace it is in, or re-derive the selected project's repositories
/// because "the project list changed".
///
/// It does neither, and the reason is where the filter sits. `workspace_id`
/// arrives on the row `ProjectDao.getAll` already reads, so narrowing is one
/// pass over a list that is in memory anyway, and the *unfiltered*
/// `sortedProjectsProvider` — which Quick Open, the phone bindings and the
/// repositories provider all hang off — is left alone. Switching contexts
/// therefore *reads* SQLite zero times, at any number of projects. It writes
/// once: the scope is kept in settings now that the Explorer's chips show it.
///
/// Counted, never timed, like every other `*_cost_test.dart` here: wall-clock
/// over a few milliseconds fails whenever the machine is busy, and statements
/// are countable directly.
void main() {
  /// 1 is the "did we make the small case worse" control; 31 is the owner's
  /// own workspace.
  const scale = [1, 10, 31];

  _CountingDatabase newDatabase() {
    final db = _CountingDatabase();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    return db;
  }

  ProviderContainer mount(_CountingDatabase db) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('w-')),
        clockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// [count] projects, a repository each, spread over four contexts the way the
  /// owner's are — and one of them selected, so the repositories provider is
  /// live and would issue a query the moment anything made it recompute.
  ({ProviderContainer container, List<String> workspaceIds}) workspaceOf(
    _CountingDatabase db,
    int count,
  ) {
    final container = mount(db);
    final workspaces = [
      for (final name in const [
        'Personal',
        'PopupBits',
        'Appwrite',
        'Game dev',
      ])
        createContext(container, name).id,
    ];
    final projects = ProjectDao(container.read(databaseProvider));
    final repositories = RepositoryDao(db);
    for (var i = 0; i < count; i++) {
      projects.insert(
        Project(
          id: 'p$i',
          name: 'Project $i',
          root: EnvironmentPath(
            environmentId: 'windows',
            path:
                r'C:\src\p'
                '$i',
          ),
          createdAt: testTime,
          // Every fourth project is left unassigned on purpose: unassigned is
          // an ordinary state and must cost the same as any other.
          workspaceId: i.isEven ? workspaces[i % 4] : null,
        ),
      );
      repositories.insert(
        Repository(
          id: 'r$i',
          projectId: 'p$i',
          name: 'app',
          path: EnvironmentPath(
            environmentId: 'windows',
            path:
                r'C:\src\p'
                '$i'
                r'\app',
          ),
          createdAt: testTime,
        ),
      );
    }
    rereadWorkspace(container);
    container.read(selectedProjectIdProvider.notifier).select('p0');
    // Mount the hot path before measuring, so its first read is not counted as
    // filter cost — and so a later recompute *would* be.
    container.read(selectedProjectRepositoriesProvider);
    container.read(workspaceScopedProjectsProvider);
    return (container: container, workspaceIds: workspaces);
  }

  group('switching contexts', () {
    final measured = <int, _Cost>{};

    for (final count in scale) {
      test('$count projects', () {
        final db = newDatabase();
        addTearDown(db.close);
        final (:container, :workspaceIds) = workspaceOf(db, count);
        final scopeOf = container.read(workspaceScopeProvider.notifier);
        db.reset();

        // Four switches: into a context, into another, into unassigned, back
        // to All — the whole cycle a user does in a morning.
        for (final scope in [
          WorkspaceScope.of(workspaceIds[0]),
          WorkspaceScope.of(workspaceIds[1]),
          WorkspaceScope.unassigned,
          WorkspaceScope.all,
        ]) {
          scopeOf.select(scope);
          container.read(workspaceScopedProjectsProvider);
          container.read(selectedProjectRepositoriesProvider);
        }

        measured[count] = _Cost(
          statements: db.statements,
          reads: db.reads,
          projectsExamined: count * 4,
        );

        // The filter still did its job.
        scopeOf.select(WorkspaceScope.of(workspaceIds[0]));
        final shown = container.read(workspaceScopedProjectsProvider);
        expect(shown, isNotEmpty);
        for (final project in shown) {
          expect(
            project.workspaceId == workspaceIds[0] || project.id == 'p0',
            isTrue,
            reason: 'only this context, plus the selected project',
          );
        }
      });
    }

    test('a switch reads nothing and writes its one setting, at any scale', () {
      expect(
        measured.keys.toSet(),
        scale.toSet(),
        reason: 'every case above must have run',
      );
      // ignore: avoid_print
      print('workspace filter cost: $measured');

      for (final count in scale) {
        expect(
          measured[count]!.statements,
          4,
          reason:
              'at $count projects: four switches, four settings writes — '
              'the list is already in memory, and nothing is asked per '
              'project',
        );
        expect(
          measured[count]!.reads,
          0,
          reason:
              'at $count projects: nothing re-derives the selected '
              "project's repositories, which is a query when it happens",
        );
      }
    });
  });

  group('assigning one project', () {
    test('costs one write and one list re-read, at any scale', () {
      final db = newDatabase();
      addTearDown(db.close);
      final (:container, :workspaceIds) = workspaceOf(db, 31);
      db.reset();

      container
          .read(workspacesControllerProvider.notifier)
          .assign('p1', workspaceIds[3]);

      expect(
        db.writes,
        1,
        reason: 'one UPDATE for the row that moved, not one per project',
      );
      expect(
        db.reads,
        3,
        reason:
            'the server checks the project and the context and reads back '
            'the one row it wrote; the app re-reads nothing — whatever the '
            'scale',
      );
      expect(
        container
            .read(projectsControllerProvider)
            .firstWhere((p) => p.id == 'p1')
            .workspaceId,
        workspaceIds[3],
      );
    });
  });
}

class _Cost {
  const _Cost({
    required this.statements,
    required this.reads,
    required this.projectsExamined,
  });

  final int statements;
  final int reads;

  /// Not a cost so much as the shape of the work that *is* done: one pass over
  /// the in-memory list per switch.
  final int projectsExamined;

  @override
  String toString() =>
      '(statements: $statements, reads: $reads, '
      'in-memory passes over: $projectsExamined)';
}

/// Counts what reaches SQLite. `package:sqlite3` is synchronous, so every one
/// of these runs on the UI isolate inside the frame.
class _CountingDatabase extends AppDatabase {
  _CountingDatabase() : super(sqlite3.openInMemory());

  int writes = 0;
  int reads = 0;

  int get statements => writes + reads;

  void reset() {
    writes = 0;
    reads = 0;
  }

  @override
  void execute(String sql, [List<Object?> params = const []]) {
    writes++;
    super.execute(sql, params);
  }

  @override
  List<Map<String, Object?>> query(
    String sql, [
    List<Object?> params = const [],
  ]) {
    reads++;
    return super.query(sql, params);
  }
}
