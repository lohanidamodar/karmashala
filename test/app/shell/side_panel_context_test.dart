import 'package:karmashala/src/app/shell/side_panel_context.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

/// The line that says which checkout the panel is describing.
///
/// It exists because the selection behind the changes, worktree, files and
/// GitHub surfaces now moves on its own: it follows the session in the terminal
/// tab. A panel that changes under the user without saying what it changed to
/// is worse than one that never moved.
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project(path: r'C:\src\demo'));
    RepositoryDao(db)
      ..insert(repository(id: 'hub', name: 'demo', path: r'C:\src\demo'))
      ..insert(
        repository(
          id: 'nested',
          name: 'app',
          path: r'C:\src\demo\projects\app',
        ),
      );
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
  });
  tearDown(() => db.close());

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: SidePanelContextLine())),
    ),
  );

  testWidgets('names the checkout and where it sits in the project', (
    tester,
  ) async {
    container.read(selectedRepositoryIdProvider.notifier).select('nested');
    await pump(tester);

    expect(find.text('app'), findsOneWidget);
    // The sub-path, not only the name: "which of these clones is it" is exactly
    // the question a hub project makes hard to answer.
    expect(find.text('projects/app'), findsOneWidget);
  });

  testWidgets('a checkout that is the project root has no sub-path', (
    tester,
  ) async {
    container.read(selectedRepositoryIdProvider.notifier).select('hub');
    await pump(tester);

    expect(find.text('demo'), findsOneWidget);
    expect(find.text('projects/app'), findsNothing);
  });

  testWidgets('with nothing selected it draws nothing', (tester) async {
    await pump(tester);

    expect(find.byType(Text), findsNothing);
  });

  test('every repository-scoped surface is one that reads the selection', () {
    // The flag decides which surfaces get the line. Adding a surface that is
    // about one checkout and forgetting it is how the panel goes back to
    // changing silently.
    expect(
      {
        for (final surface in SidePanelSurface.values)
          if (surface.scopedToRepository) surface,
      },
      {
        SidePanelSurface.changes,
        SidePanelSurface.github,
        SidePanelSurface.files,
        SidePanelSurface.repository,
      },
    );
  });
}
