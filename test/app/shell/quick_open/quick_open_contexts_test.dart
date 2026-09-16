import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/quick_open/quick_open.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/workspaces/application/workspaces_controller.dart';
import 'package:karmashala/src/features/workspaces/domain/workspace_scope.dart';

import '../../../features/terminal/fake_instance.dart';
import '../../../support/fakes.dart';
import '../../../support/fixtures.dart';

/// **Switching context from the palette.**
///
/// A context is a filter over the project list, and a filter you have to find a
/// menu for is a filter you leave switched on. The palette is where the app's
/// other "take me somewhere" answers already live, so the contexts are a group
/// in it — including *All projects*, because getting back to everything is the
/// move people make most and the way out must not be harder to reach than the
/// way in.
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    ProjectDao(db).insert(project(name: 'Karmashala'));
    RepositoryDao(db).insert(repository(name: 'app'));
    AgentInstallationDao(db).insert(agentInstallation());
  });
  tearDown(() => db.close());

  Future<ProviderContainer> open(
    WidgetTester tester, {
    void Function(ProviderContainer container)? before,
  }) async {
    final container = ProviderContainer(
      overrides: [...fakeTerminalOverrides(database: db)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => QuickOpen.show(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    container.read(selectedProjectIdProvider.notifier).select('p1');
    container.read(selectedRepositoryIdProvider.notifier).select('r1');
    before?.call(container);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> type(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.pumpAndSettle();
  }

  testWidgets('a context is one search away, and switching to it is one tap', (
    tester,
  ) async {
    late String gamesId;
    final container = await open(
      tester,
      before: (container) {
        final workspaces = container.read(
          workspacesControllerProvider.notifier,
        );
        workspaces.create('Personal');
        gamesId = workspaces
            .create('Game dev', description: 'Weekend things')
            .id;
      },
    );

    await type(tester, 'game');
    expect(find.text('CONTEXTS'), findsOneWidget);
    expect(find.text('Game dev'), findsOneWidget);
    // The description is the subtitle, so two similarly named contexts are
    // told apart before you commit to one.
    expect(find.text('Weekend things'), findsOneWidget);

    await tester.tap(find.text('Game dev'));
    await tester.pumpAndSettle();

    expect(container.read(workspaceScopeProvider), WorkspaceScope.of(gamesId));
  });

  testWidgets('"All projects" is in the group, and gets everything back', (
    tester,
  ) async {
    final container = await open(
      tester,
      before: (container) {
        final games = container
            .read(workspacesControllerProvider.notifier)
            .create('Game dev');
        container
            .read(workspaceScopeProvider.notifier)
            .select(WorkspaceScope.of(games.id));
      },
    );

    await type(tester, 'all projects');
    expect(find.text('All projects'), findsOneWidget);
    // The one you are already on says so rather than looking like a dead row.
    await tester.tap(find.text('All projects'));
    await tester.pumpAndSettle();

    expect(container.read(workspaceScopeProvider), WorkspaceScope.all);
    expect(container.read(workspaceScopedProjectsProvider), hasLength(1));
  });

  testWidgets('the current scope is marked, not hidden', (tester) async {
    await open(
      tester,
      before: (container) {
        container.read(workspacesControllerProvider.notifier).create('Personal');
      },
    );
    await type(tester, 'all projects');
    expect(find.text('Showing'), findsOneWidget);
  });

  testWidgets('with no contexts the palette offers none', (tester) async {
    await open(tester);
    await type(tester, 'context');
    expect(
      find.text('CONTEXTS'),
      findsNothing,
      reason: 'a filter with nothing to filter by is not a thing to offer',
    );
  });
}
