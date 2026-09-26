import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala/src/features/workspaces/application/workspaces_controller.dart';
import 'package:karmashala/src/features/workspaces/domain/workspace_scope.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// **What switching contexts costs, counted.**
///
/// The project list and `selectedProjectRepositoriesProvider` are hot paths
/// this app has already had to fix twice, and a scope filter is exactly the
/// kind of feature that quietly puts a query behind every row: ask each project
/// which workspace it is in, or re-derive the selected project's repositories
/// because "the project list changed".
///
/// It does neither, and the reason is where the filter sits. `workspace_id`
/// arrives on the project row the app already holds, so narrowing is one
/// pass over a list that is in memory anyway, and the *unfiltered*
/// `sortedProjectsProvider` — which Quick Open, the phone bindings and the
/// repositories provider all hang off — is left alone. Switching contexts
/// therefore touches SQLite zero times, at any number of projects. It writes
/// one setting, at the server: the scope is kept in settings now that the
/// Explorer's chips show it.
///
/// Counted, never timed, like every other `*_cost_test.dart` here: wall-clock
/// over a few milliseconds fails whenever the machine is busy, and statements
/// are countable directly.
void main() {
  /// 1 is the "did we make the small case worse" control; 31 is the owner's
  /// own workspace.
  const scale = [1, 10, 31];

  // Settings are written at the server, not to SQLite: counted there.
  late FakeDataServer server;
  late DataClient data;
  setUp(() async {
    server = FakeDataServer();
    data = await server.connect();
  });

  CountingMachine newDatabase() {
    final db = CountingMachine();
    server.environmentRows.upsert(windowsEnv());
    return db;
  }

  ProviderContainer mount(CountingMachine db) {
    final container = ProviderContainer(
      overrides: [
        dataClientProvider.overrideWithValue(data),
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
  Future<({ProviderContainer container, List<String> workspaceIds})> seeded(
    CountingMachine db,
    int count,
  ) async {
    final container = mount(db);
    final workspaces = [
      for (final name in const [
        'Personal',
        'PopupBits',
        'Appwrite',
        'Game dev',
      ])
        (await createContext(container, name)).id,
    ];
    for (var i = 0; i < count; i++) {
      server.projectRows.insert(
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
      server.repositoryRows.insert(
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
      test('$count projects', () async {
        final db = newDatabase();
        final (:container, :workspaceIds) = await seeded(db, count);
        final scopeOf = container.read(workspaceScopeProvider.notifier);
        db.reset();
        server.requests.clear();

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

        await pumpEventQueue();
        measured[count] = _Cost(
          statements: db.count,
          settingsWrites: server.requests
              .where((kind) => kind == 'preferences.set')
              .length,
          reads: db.reads.length,
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

    test('a switch touches SQLite not at all and writes its one setting, '
        'at any scale', () {
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
          0,
          reason:
              'at $count projects: the list is already in memory, and '
              'nothing is asked per project',
        );
        expect(
          measured[count]!.settingsWrites,
          4,
          reason: 'at $count projects: four switches, four settings writes',
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
    test('costs one write and no re-read, at any scale', () async {
      final db = newDatabase();
      final (:container, :workspaceIds) = await seeded(db, 31);
      db.reset();
      server.requests.clear();

      await container
          .read(workspacesControllerProvider.notifier)
          .assign('p1', workspaceIds[3]);

      expect(
        server.requests,
        hasLength(1),
        reason: 'one write for the row that moved, not one per project',
      );
      expect(
        db.reads,
        isEmpty,
        reason:
            'the server files the project and answers with the one row it '
            'wrote; the app re-reads nothing — whatever the scale',
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
    required this.settingsWrites,
    required this.reads,
    required this.projectsExamined,
  });

  final int statements;
  final int settingsWrites;
  final int reads;

  /// Not a cost so much as the shape of the work that *is* done: one pass over
  /// the in-memory list per switch.
  final int projectsExamined;

  @override
  String toString() =>
      '(statements: $statements, settings writes: $settingsWrites, '
      'reads: $reads, '
      'in-memory passes over: $projectsExamined)';
}
