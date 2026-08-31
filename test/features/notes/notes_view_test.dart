import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/notes/application/composer_draft.dart';
import 'package:chitragupta/src/features/notes/application/notes_providers.dart';
import 'package:chitragupta/src/features/notes/presentation/note_edit_dialog.dart';
import 'package:chitragupta/src/features/notes/presentation/notes_view.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/sessions/application/session_providers.dart';
import 'package:chitragupta/src/features/sessions/application/session_ui_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

void main() {
  /// The panel this lives in, at the width it actually gets on a desktop.
  Future<ProviderContainer> pump(
    WidgetTester tester, {
    bool withSession = true,
  }) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    if (withSession) {
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      ProjectDao(db).insert(project());
      RepositoryDao(db).insert(repository());
      AgentInstallationDao(db).insert(agentInstallation());
    }
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    if (withSession) {
      container
          .read(sessionDaoProvider)
          .insert(session(title: 'Toolbar rework'));
    }

    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                SizedBox(width: 320, child: NotesView()),
                Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('the empty panel teaches what a note is and how to make one', (
    tester,
  ) async {
    await pump(tester);

    expect(find.text('No notes yet.'), findsOneWidget);
    expect(find.textContaining('without acting on it'), findsOneWidget);
    expect(find.textContaining('note button under any message'), findsOneWidget);
    // And what happens next, which is the half that makes it a feature.
    expect(find.textContaining('send it back'), findsOneWidget);
  });

  testWidgets('a note shows its first line and where it came from', (
    tester,
  ) async {
    final container = await pump(tester);
    container
        .read(notesProvider.notifier)
        .capture(
          body: 'Give the tab strip a compact mode\nreusing Chrome.row',
          sourceSessionId: 's1',
          sourceRepositoryId: 'r1',
          sourceMessageOrdinal: 2,
          sourceMessageRole: 'agent',
        );
    await tester.pumpAndSettle();

    expect(find.text('Give the tab strip a compact mode'), findsOneWidget);
    expect(
      find.textContaining('From Toolbar rework'),
      findsOneWidget,
      reason: 'the note must answer "what were we discussing?"',
    );
    expect(find.textContaining('the agent’s reply'), findsOneWidget);
  });

  testWidgets('a long note is clipped in the list, never rewritten', (
    tester,
  ) async {
    final long = List.generate(
      60,
      (i) => 'line $i of a very long thought that keeps going and going',
    ).join('\n');
    final container = await pump(tester);
    final note = container
        .read(notesProvider.notifier)
        .capture(body: long, sourceSessionId: 's1');
    await tester.pumpAndSettle();

    // Rendering a 60-line note in a 320px panel must not overflow.
    expect(tester.takeException(), isNull);
    // Clipping is a display choice; the stored note is whole.
    expect(container.read(noteDaoProvider).getById(note.id)!.body, long);
  });

  testWidgets('a note can be retitled and rewritten', (tester) async {
    final container = await pump(tester);
    final note = container
        .read(notesProvider.notifier)
        .capture(body: 'first draft', sourceSessionId: 's1');
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Edit note'));
    await tester.pumpAndSettle();
    expect(find.byType(NoteEditDialog), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Title (optional)'),
      'Tab strip density',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Note'),
      'second draft, with the actual idea',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final stored = container.read(noteDaoProvider).getById(note.id)!;
    expect(stored.title, 'Tab strip density');
    expect(stored.body, 'second draft, with the actual idea');
    expect(find.text('Tab strip density'), findsOneWidget);
    // The origin survives the edit.
    expect(stored.sourceSessionId, 's1');
  });

  testWidgets('a note can be deleted', (tester) async {
    final container = await pump(tester);
    container.read(notesProvider.notifier).capture(body: 'never mind');
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete note'));
    await tester.pumpAndSettle();

    expect(container.read(notesProvider), isEmpty);
    expect(container.read(noteDaoProvider).list(), isEmpty);
    expect(find.text('No notes yet.'), findsOneWidget);
  });

  testWidgets('sending back queues the note for its own session, unsent', (
    tester,
  ) async {
    final container = await pump(tester);
    container
        .read(notesProvider.notifier)
        .capture(body: 'compact tab strip, please', sourceSessionId: 's1');
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Send to Toolbar rework’s message box'));
    await tester.pumpAndSettle();

    expect(
      container.read(composerDraftProvider),
      containsPair('s1', 'compact tab strip, please'),
    );
    // And that session is brought up, so the box is the one on screen.
    expect(container.read(selectedSessionIdProvider), 's1');
  });

  testWidgets('a note with no session of its own goes to the open one', (
    tester,
  ) async {
    final container = await pump(tester);
    container.read(selectedSessionIdProvider.notifier).select('s1');
    container.read(notesProvider.notifier).capture(body: 'written here');
    await tester.pumpAndSettle();

    expect(find.text('Written here'), findsOneWidget);
    await tester.tap(find.byTooltip('Send to Toolbar rework’s message box'));
    await tester.pumpAndSettle();

    expect(
      container.read(composerDraftProvider),
      containsPair('s1', 'written here'),
    );
  });

  testWidgets('with nothing open, sending back is offered but disabled', (
    tester,
  ) async {
    final container = await pump(tester, withSession: false);
    container.read(notesProvider.notifier).capture(body: 'someday');
    await tester.pumpAndSettle();

    final send = find.byTooltip(
      'No session to send this to — open one first',
    );
    expect(send, findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(of: send, matching: find.byType(IconButton)).first,
          )
          .onPressed,
      isNull,
    );
    expect(container.read(composerDraftProvider), isEmpty);
  });

  testWidgets('a note whose session is gone still says where it came from', (
    tester,
  ) async {
    final container = await pump(tester);
    container
        .read(notesProvider.notifier)
        .capture(body: 'outlives its session', sourceSessionId: 'deleted');
    await tester.pumpAndSettle();

    // Once as the note's name (its first line), once as its preview.
    expect(find.text('outlives its session'), findsNWidgets(2));
    expect(
      find.textContaining('From a session that is gone'),
      findsOneWidget,
    );
  });
}
