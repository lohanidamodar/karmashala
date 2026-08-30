import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/core/process/command_runner_providers.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/explorer/presentation/explorer_panel.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';

void main() {
  testWidgets('filters the project tree by the search query', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db)
      ..insert(project(id: 'p1', name: 'Alpha', path: r'C:\src\alpha'))
      ..insert(project(id: 'p2', name: 'Beta', path: r'C:\src\beta'));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
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
}
