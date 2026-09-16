import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/todos/presentation/todo_edit_dialog.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_ui/dialogs.dart';

import '../../support/fixtures.dart';

void main() {
  testWidgets('the todo composer wears the house title', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(home: TodoEditDialog(body: 'buy milk')),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<DesktopDialogTitle>(find.byType(DesktopDialogTitle)).title,
      'New todo',
    );
  });
}
