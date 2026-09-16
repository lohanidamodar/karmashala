import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/quick_open/quick_open.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/notes/application/note_drafts.dart';
import 'package:karmashala/src/features/notes/application/notes_providers.dart';
import 'package:karmashala/src/features/notes/presentation/note_tab_view.dart';
import 'package:karmashala_ui/code.dart';
import 'package:karmashala/src/features/todos/application/todos_providers.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// **Can somebody who has never read the code find where to write one?**
///
/// The owner could not: *"about notes, how to add notes, where can we add
/// notes?"*, and then *"it's not intuitive"*. Notes had a side-panel surface,
/// a per-message capture glyph and an MCP tool — three doors, all of which you
/// have to already know about. The palette listed the surface, but only as a
/// *place* ("Notes  ·  Side panel"), and a place only answers the question if
/// you already know its name.
///
/// So these walk the app the way a person does, from a control that is visible
/// on screen with nothing typed: click the search box in the title bar, type
/// the word for the thing you want, press the row. Nothing here calls a
/// provider to get where it is going, because the claim being tested is that
/// you do not have to.
void main() {
  Future<void> settle(WidgetTester tester) async {
    try {
      await tester.pumpAndSettle(
        const Duration(milliseconds: 16),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 2),
      );
    } on FlutterError catch (error) {
      if (!error.message.contains('pumpAndSettle timed out')) rethrow;
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    final container = fakeTerminalContainer(database: db);
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KarmashalaApp(),
      ),
    );
    await settle(tester);
    return container;
  }

  /// Click the palette's own button — a visible control in the title bar, not
  /// a chord you have to be told — and type [query] into it.
  Future<void> search(WidgetTester tester, String query) async {
    expect(
      find.byType(QuickOpenButton),
      findsOneWidget,
      reason: 'the way in has to be on screen before anything is typed',
    );
    await tester.tap(find.byType(QuickOpenButton));
    await settle(tester);
    await tester.enterText(
      find.descendant(
        of: find.byType(QuickOpen),
        matching: find.byType(TextField),
      ),
      query,
    );
    await settle(tester);
  }

  testWidgets('typing "todo" offers a verb, and it lands on a typable field', (
    tester,
  ) async {
    final container = await pumpApp(tester);

    await search(tester, 'todo');
    expect(
      find.text('New todo'),
      findsOneWidget,
      reason:
          'the palette answers "todo" with something you can do, not only '
          'with a panel you would have to know the name of',
    );

    await tester.tap(find.text('New todo'));
    await settle(tester);

    // It opened the surface, so next time the panel itself is findable...
    expect(container.read(sidePanelProvider), SidePanelSurface.todos);
    // ...and it put the cursor where the todo goes, so the walk ends in
    // typing rather than in looking for the next thing to click.
    expect(find.text('New todo'), findsOneWidget, reason: 'the composer hint');
    await tester.enterText(
      find.widgetWithText(TextField, 'New todo'),
      'buy milk',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    expect(container.read(todosProvider).single.body, 'buy milk');
    expect(find.text('buy milk'), findsOneWidget);
  });

  testWidgets('the word people actually use finds it too', (tester) async {
    await pumpApp(tester);
    await search(tester, 'task');
    expect(find.text('New todo'), findsOneWidget);
  });

  testWidgets('typing "note" offers writing one, and opens the editor', (
    tester,
  ) async {
    final container = await pumpApp(tester);

    await search(tester, 'note');
    expect(find.text('New note…'), findsOneWidget);

    await tester.tap(find.text('New note…'));
    await settle(tester);

    // The note is open in its tab, on the editor, and the panel behind it is
    // the one that lists it.
    expect(find.byType(NoteTabView), findsOneWidget);
    expect(container.read(sidePanelProvider), SidePanelSurface.notes);

    tester
            .widget<AppCodeEditor>(
              find.descendant(
                of: find.byType(NoteTabView),
                matching: find.byType(AppCodeEditor),
              ),
            )
            .controller
            .text =
        'the toolbar needs a compact mode';
    await tester.pump(NoteDrafts.autosaveDelay);
    await settle(tester);

    expect(
      container.read(notesProvider).single.body,
      'the toolbar needs a compact mode',
    );
  });

  testWidgets('and the empty Notes panel names the way in', (tester) async {
    // The other half of the report: somebody who *does* find the panel used to
    // be met with three paragraphs pointing at a glyph somewhere else.
    final container = await pumpApp(tester);
    container.read(sidePanelProvider.notifier).select(SidePanelSurface.notes);
    await settle(tester);

    expect(find.textContaining('No notes yet.'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Write a note'));
    await settle(tester);

    expect(find.byType(NoteTabView), findsOneWidget, reason: 'the note opened');
  });
}
