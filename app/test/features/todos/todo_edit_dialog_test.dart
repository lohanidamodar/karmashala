import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/todos/presentation/todo_edit_dialog.dart';
import 'package:karmashala_ui/dialogs.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';

void main() {
  testWidgets('the todo composer wears the house title', (tester) async {
    final server = FakeDataServer()..environmentRows.upsert(windowsEnv());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [await server.override()],
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
