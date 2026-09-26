import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/quick_open/quick_open.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/workspaces/application/workspaces_controller.dart';
import 'package:karmashala/src/features/workspaces/domain/workspace_scope.dart';

import '../../../features/terminal/fake_instance.dart';
import '../../../support/fakes.dart';
import '../../../support/fixtures.dart';
import '../../../support/fake_data_server.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import '../../../support/test_machine.dart';

/// **Switching context from the palette.**
///
/// A context is a filter over the project list, and a filter you have to find a
/// menu for is a filter you leave switched on. The palette is where the app's
/// other "take me somewhere" answers already live, so the contexts are a group
/// in it — including *All projects*, because getting back to everything is the
/// move people make most and the way out must not be harder to reach than the
/// way in.
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late Override data;

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer();
    data = await server.override();
    server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
    server.projectRows.insert(project(name: 'Karmashala'));
    server.repositoryRows.insert(repository(name: 'app'));
    server.installationRows.insert(agentInstallation());
  });

  Future<ProviderContainer> open(
    WidgetTester tester, {
    Future<void> Function(ProviderContainer container)? before,
  }) async {
    final container = ProviderContainer(
      overrides: [
        data,
        ...fakeTerminalOverrides(machine: db),
      ],
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
    await before?.call(container);
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
      before: (container) async {
        await createContext(container, 'Personal');
        gamesId = (await createContext(
          container,
          'Game dev',
          description: 'Weekend things',
        )).id;
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
      before: (container) async {
        final games = await createContext(container, 'Game dev');
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
      before: (container) async {
        await container
            .read(workspacesControllerProvider.notifier)
            .create('Personal');
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
