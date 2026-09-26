import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';

void main() {
  testWidgets('filters the project tree by the search query', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    final server = FakeDataServer();
    server.projectRows
      ..insert(project(id: 'p1', name: 'Alpha', path: r'C:\src\alpha'))
      ..insert(project(id: 'p2', name: 'Beta', path: r'C:\src\beta'));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          await server.override(),
          // A session card asks git for its checkout's changes; a widget test
          // must never spawn one.
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: ExplorerPanel())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'beta');
    await tester.pumpAndSettle();

    expect(find.text('Alpha'), findsNothing);
    expect(find.text('Beta'), findsOneWidget);
  });

  testWidgets(
    'a search typed from deep in the list starts at its first match',
    (tester) async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      final server = FakeDataServer();
      for (var i = 0; i < 80; i++) {
        final n = '$i'.padLeft(2, '0');
        server.projectRows.insert(
          project(id: 'p$n', name: 'Project $n', path: 'C:\\src\\p$n'),
        );
      }
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            await server.override(),
            commandRunnerFactoryProvider.overrideWithValue(
              FakeCommandRunnerFactory(),
            ),
          ],
          child: const MaterialApp(home: Scaffold(body: ExplorerPanel())),
        ),
      );
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView), const Offset(0, -2000));
      await tester.pumpAndSettle();
      // The list's own position, not the search field's.
      double listOffset() => tester
          .state<ScrollableState>(
            find.descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            ),
          )
          .position
          .pixels;
      expect(find.text('Project 00'), findsNothing, reason: 'it did scroll');
      expect(listOffset(), greaterThan(0));

      await tester.enterText(find.byType(TextField), 'Project 0');
      await tester.pumpAndSettle();
      expect(find.text('Project 00'), findsOneWidget);
      expect(find.text('Project 09'), findsOneWidget);
      expect(listOffset(), 0);

      // Clearing it lands at the top too, never where the old list was left.
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      expect(find.text('Project 00'), findsOneWidget);
    },
  );
}
