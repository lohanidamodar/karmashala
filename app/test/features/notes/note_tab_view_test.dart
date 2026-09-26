import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/notes/application/notes_providers.dart';
import 'package:karmashala/src/features/notes/presentation/note_tab_view.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
import '../terminal/fake_instance.dart';
import 'package:karmashala_notes/store.dart';
import 'package:karmashala/src/core/database/database_providers.dart';

const _longBody =
    '# Rework the tab strip\n\n'
    'So a session that has been renamed still shows the branch it is on, and '
    'the overflow menu lists the panes that no longer fit rather than '
    'silently dropping them off the end of the row.\n\n'
    '- one\n- two\n\n```dart\nfinal x = 1;\n```\n';

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late String noteId;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    container = ProviderContainer(
      overrides: fakeTerminalOverrides(database: db),
    );
    noteId = container
        .read(notesProvider.notifier)
        .capture(
          body: _longBody,
          title: 'A deliberately long title for a note about the tab strip',
          projectId: 'p1',
        )
        .id;
  });
  tearDown(() {
    container.dispose();
    db.close();
  });

  Widget app() => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: AppTheme.light(),
      builder: (context, inner) => UiDensity.wrap(context, inner!),
      home: Scaffold(body: NoteTabView(noteId: noteId)),
    ),
  );

  testWidgets('survives the window matrix, in preview and in edit', (
    tester,
  ) async {
    await expectSurvivesWindowMatrix(tester, build: app);
    await expectSurvivesWindowMatrix(
      tester,
      build: app,
      warmUp: (tester) async {
        await tester.tap(find.text('Edit'));
        await tester.pumpAndSettle();
      },
    );
  });

  testWidgets('the tab re-files a note, and can unfile it', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    // It opens on the note's current filing.
    expect(find.text('Demo'), findsOneWidget);
    await tester.tap(find.text('Demo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('No project').last);
    await tester.pumpAndSettle();

    final stored = NoteDao(container.read(databaseProvider)).getById(noteId)!;
    expect(stored.projectId, isNull);
    expect(find.text('No project'), findsOneWidget);
  });

  testWidgets('a narrow tab stacks its metadata; a wide one lays it out in '
      'a row', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    tester.view.physicalSize = const Size(420, 800);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final projectNarrow = tester.getTopLeft(find.text('Project'));
    final createdNarrow = tester.getTopLeft(
      find.textContaining('Created').first,
    );
    expect(createdNarrow.dy, greaterThan(projectNarrow.dy));

    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpAndSettle();
    final projectWide = tester.getCenter(find.text('Project'));
    final createdWide = tester.getCenter(find.textContaining('Created').first);
    expect(createdWide.dy, closeTo(projectWide.dy, 4));
  });
}
