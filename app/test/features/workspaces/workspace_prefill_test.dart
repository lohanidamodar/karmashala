import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala/src/features/projects/presentation/new_project_dialog.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/repositories/application/repository_discovery_provider.dart';
import 'package:karmashala/src/features/workspaces/application/workspaces_controller.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// The prefill is a *guess*: it is offered, it is overridable, and it never
/// touches a project that already exists.
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late FakeDataServer server;

  setUp(() async {
    db = AppDatabase.memory();
    server = FakeDataServer(clock: () => testTime);
    server.environmentRows.upsert(windowsEnv());
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        await server.override(),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('new-')),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        repositoryDiscoveryServiceProvider.overrideWithValue(
          FakeRepositoryDiscoveryService(),
        ),
        autoImportRunnerProvider.overrideWithValue(
          (_) async => const ImportSummary(),
        ),
      ],
    );
    addTearDown(container.dispose);
  });
  tearDown(() => db.close());

  /// A context holding one project, so the folder has something to be near.
  Future<Workspace> seedGames() async {
    final games = await createContext(container, 'Game dev');
    server.projectRows.insert(
      Project(
        id: 'p-existing',
        name: 'Roguelike',
        root: const EnvironmentPath(
          environmentId: 'windows',
          path: r'C:\Users\dlohani\projects\games\roguelike',
        ),
        createdAt: testTime,
        workspaceId: games.id,
      ),
    );
    return games;
  }

  Future<void> pumpDialog(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: NewProjectDialog())),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> typeFolder(WidgetTester tester, String path) async {
    await tester.enterText(find.widgetWithText(TextField, 'Folder path'), path);
    await tester.pumpAndSettle();
  }

  /// What the context dropdown is showing.
  String shownContext(WidgetTester tester) {
    final field = find.byType(DropdownButtonFormField<String?>);
    expect(field, findsOneWidget);
    return tester
        .widgetList<Text>(
          find.descendant(of: field, matching: find.byType(Text)),
        )
        .map((t) => t.data)
        .whereType<String>()
        .firstWhere(
          (text) => text != 'Context' && !text.startsWith('Suggested'),
        );
  }

  testWidgets('the folder prefills the context it sits nearest', (
    tester,
  ) async {
    await seedGames();
    await pumpDialog(tester);
    expect(shownContext(tester), 'None');

    await typeFolder(tester, r'C:\Users\dlohani\projects\games\shmup');

    expect(shownContext(tester), 'Game dev');
  });

  testWidgets('the guess is overridable, and stays overridden', (tester) async {
    await seedGames();
    await createContext(container, 'Personal');
    await pumpDialog(tester);
    await typeFolder(tester, r'C:\Users\dlohani\projects\games\shmup');
    expect(shownContext(tester), 'Game dev');

    await tester.tap(find.byType(DropdownButtonFormField<String?>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Personal').last);
    await tester.pumpAndSettle();
    expect(shownContext(tester), 'Personal');

    // A later folder edit must not overwrite an answer the user gave.
    await typeFolder(tester, r'C:\Users\dlohani\projects\games\platformer');
    expect(shownContext(tester), 'Personal');
  });

  testWidgets('"None" is a complete answer and survives a re-guess', (
    tester,
  ) async {
    await seedGames();
    await pumpDialog(tester);
    await typeFolder(tester, r'C:\Users\dlohani\projects\games\shmup');
    expect(shownContext(tester), 'Game dev');

    await tester.tap(find.byType(DropdownButtonFormField<String?>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('None').last);
    await tester.pumpAndSettle();

    await typeFolder(tester, r'C:\Users\dlohani\projects\games\platformer');
    expect(shownContext(tester), 'None');
  });

  testWidgets('a folder near nothing suggests nothing', (tester) async {
    await seedGames();
    await pumpDialog(tester);

    await typeFolder(tester, r'D:\somewhere\else');

    expect(shownContext(tester), 'None');
  });

  testWidgets('the prefill never reassigns an existing project', (
    tester,
  ) async {
    final games = await seedGames();
    // A second, unassigned project sitting right beside the filed one — the
    // exact case an eager classifier would "helpfully" file.
    server.projectRows.insert(
      Project(
        id: 'p-unfiled',
        name: 'Platformer',
        root: const EnvironmentPath(
          environmentId: 'windows',
          path: r'C:\Users\dlohani\projects\games\platformer',
        ),
        createdAt: testTime,
      ),
    );

    await pumpDialog(tester);
    await typeFolder(tester, r'C:\Users\dlohani\projects\games\shmup');
    expect(shownContext(tester), 'Game dev');

    final byId = {
      for (final p in container.read(projectsControllerProvider)) p.id: p,
    };
    expect(byId['p-unfiled']!.workspaceId, isNull);
    expect(byId['p-existing']!.workspaceId, games.id);
  });

  testWidgets('a new context can be named inline, and nothing is written '
      'until the project is', (tester) async {
    await pumpDialog(tester);
    await tester.tap(find.byTooltip('New context'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'New context'),
      'Appwrite',
    );
    await tester.pumpAndSettle();

    expect(
      container.read(workspacesControllerProvider),
      isEmpty,
      reason: 'typing a name is not creating a context',
    );

    // Backing out leaves nothing behind either.
    await tester.tap(find.byTooltip('Pick an existing context instead'));
    await tester.pumpAndSettle();
    expect(container.read(workspacesControllerProvider), isEmpty);
    expect(find.byType(DropdownButtonFormField<String?>), findsOneWidget);
  });
}
