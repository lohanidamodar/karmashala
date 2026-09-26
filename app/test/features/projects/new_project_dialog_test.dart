import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/projects/presentation/new_project_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

/// The dialog's environment list is the one place a project's *namespace* is
/// chosen, so what it offers has to be what the app can actually create.
void main() {
  late AppDatabase db;
  late Override data;

  setUp(() async {
    db = AppDatabase.memory();
    final server = FakeDataServer();
    final dao = server.environmentRows
      ..upsert(windowsEnv())
      ..upsert(wslEnv())
      ..upsert(
        ExecutionEnvironment(
          id: 'ssh:h1',
          kind: EnvironmentKind.ssh,
          name: 'build-box',
          sshHostId: 'h1',
          createdAt: testTime,
        ),
      );
    expect(dao.getAll(), hasLength(3));
    data = await server.override();
  });
  tearDown(() => db.close());

  Future<void> pumpDialog(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db), data],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: NewProjectDialog())),
      ),
    );
    await tester.pumpAndSettle();
    // Open the environment dropdown.
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
  }

  testWidgets('an SSH environment is offered as a target', (tester) async {
    await pumpDialog(tester);

    expect(find.text('SSH · build-box'), findsOneWidget);
  });

  testWidgets('WSL rows are labelled WSL and Windows is labelled Windows', (
    tester,
  ) async {
    await pumpDialog(tester);

    expect(find.text('Windows'), findsWidgets);
    expect(find.text('WSL · Ubuntu'), findsWidgets);
  });
}
