import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala_notes/karmashala_notes.dart';
import 'package:karmashala/src/features/notes/presentation/note_edit_dialog.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_store/database.dart';

import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';

void main() {
  testWidgets('a note being written is titled as new, in the house title', (
    tester,
  ) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    final at = DateTime.utc(2026, 9, 16);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: NoteEditDialog(
            note: Note(id: '', body: '', createdAt: at, updatedAt: at),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<DesktopDialogTitle>(find.byType(DesktopDialogTitle)).title,
      'New note',
    );
  });

  testWidgets('a long note keeps the whole field inside the window', (
    tester,
  ) async {
    final body = [
      for (var i = 1; i <= 40; i++) 'Line $i of a note pasted from a session.',
    ].join('\n');
    await expectSurvivesWindowMatrix(
      tester,
      because:
          'a body field of 16 lines is taller than the dialog at 720x560, so '
          'its label scrolled out of sight while typing',
      build: () {
        final db = AppDatabase.memory();
        addTearDown(db.close);
        ExecutionEnvironmentDao(db).upsert(windowsEnv());
        ProjectDao(db).insert(project());
        final container = ProviderContainer(
          overrides: [databaseProvider.overrideWithValue(db)],
        );
        addTearDown(container.dispose);
        final at = DateTime.utc(2026, 9, 16);
        return UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: NoteEditDialog(
              note: Note(id: 'n1', body: body, createdAt: at, updatedAt: at),
            ),
          ),
        );
      },
    );
  });
}
