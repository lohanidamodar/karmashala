import 'package:karmashala/src/app/shell/side_panel_context.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala_projects/store.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/explorer/application/checkout_picker.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_ui/tokens.dart';
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

  testWidgets('a long worktree branch fits the narrowest panel', (
    tester,
  ) async {
    final worktrees = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        selectedCheckoutWorktreesProvider.overrideWith(
          (ref) async => const [
            GitWorktree(
              path: EnvironmentPath(
                environmentId: 'windows',
                path: r'C:\src\demo\wt\login',
              ),
              branch: 'session/fix-the-login-form-validation',
            ),
          ],
        ),
      ],
    );
    addTearDown(worktrees.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: worktrees,
        child: const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 240, child: SidePanelWorktrees()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('session/fix'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the context line grows with the text size', (tester) async {
    container.read(selectedRepositoryIdProvider.notifier).select('nested');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2)),
          child: MaterialApp(home: Scaffold(body: SidePanelContextLine())),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(SidePanelContextLine)).height,
      greaterThan(Chrome.statusBar),
    );
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
