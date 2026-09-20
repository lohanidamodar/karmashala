@Tags(['cost'])
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/notes/application/notes_providers.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/terminal_instance.dart';
import 'package:karmashala/src/features/todos/application/todos_providers.dart';

import '../features/terminal/fake_instance.dart';
import '../support/fakes.dart';
import '../support/fixtures.dart';

/// Right-click a terminal selection and keep it: as a todo, or as a note.
///
/// The two rows are the terminal's door into the two surfaces an agent already
/// reaches through `todo_add` and `note_add`. What they must get right is the
/// part a tool call gets for free and a pane does not: **which project the text
/// came from**, and the fact that a plain shell came from none.
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  /// A workbench over one plain shell tab, at a desktop size.
  Future<String> pump(WidgetTester tester, {bool notesEnabled = true}) async {
    db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());

    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        notesEnabledProvider.overrideWithValue(notesEnabled),
      ],
    );
    addTearDown(container.dispose);

    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: WorkbenchView()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .focusedPaneId;
  }

  TerminalInstance instanceOf(String paneId) => container
      .read(terminalSessionsControllerProvider.notifier)
      .instanceFor(paneId)!;

  /// Binds session `s1` — in repository `r1`, project `p1` — to [paneId].
  void runSessionIn(String paneId) {
    SessionDao(db)
      ..insert(session())
      ..updatePaneId('s1', paneId);
  }

  /// Writes [text] into the pane and selects from (0,0) to [to] on [row].
  Future<void> selectIn(
    WidgetTester tester,
    String paneId,
    String text, {
    int to = 0,
    int row = 0,
  }) async {
    final instance = instanceOf(paneId);
    instance.terminal.write(text);
    await tester.pumpAndSettle();
    final buffer = instance.terminal.buffer;
    instance.controller.setSelection(
      buffer.createAnchor(0, 0),
      buffer.createAnchor(to, row),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tapAt(const Offset(400, 400), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets('with nothing selected, neither row is offered', (tester) async {
    await pump(tester);
    await openMenu(tester);

    expect(find.text('Create todo from selection'), findsNothing);
    expect(find.text('Create note from selection'), findsNothing);
  });

  testWidgets('a selection of nothing but blanks is not a capture either', (
    tester,
  ) async {
    final paneId = await pump(tester);
    await selectIn(tester, paneId, '     ', to: 5);
    await openMenu(tester);

    expect(find.text('Create todo from selection'), findsNothing);
    expect(find.text('Create note from selection'), findsNothing);
  });

  testWidgets('a selection offers both rows', (tester) async {
    final paneId = await pump(tester);
    await selectIn(tester, paneId, 'hello  world', to: 12);
    await openMenu(tester);

    expect(find.text('Create todo from selection'), findsOneWidget);
    expect(find.text('Create note from selection'), findsOneWidget);
  });

  testWidgets('with Notes switched off only the todo row is offered', (
    tester,
  ) async {
    final paneId = await pump(tester, notesEnabled: false);
    await selectIn(tester, paneId, 'hello  world', to: 12);
    await openMenu(tester);

    expect(find.text('Create todo from selection'), findsOneWidget);
    expect(
      find.text('Create note from selection'),
      findsNothing,
      reason:
          'a row that writes into a surface the user switched off is a '
          'row that files work where nobody will look for it',
    );
  });

  testWidgets('a note keeps the selection word for word, spaces and all', (
    tester,
  ) async {
    final paneId = await pump(tester);
    runSessionIn(paneId);
    await selectIn(tester, paneId, 'two  spaces  here', to: 17);
    await openMenu(tester);
    await choose(tester, 'Create note from selection');
    await choose(tester, 'Save');

    final note = container.read(notesProvider).single;
    expect(note.body, 'two  spaces  here');
  });

  testWidgets('a note taken in a session records where it came from', (
    tester,
  ) async {
    final paneId = await pump(tester);
    runSessionIn(paneId);
    await selectIn(tester, paneId, 'the failing line', to: 16);
    await openMenu(tester);
    await choose(tester, 'Create note from selection');
    await choose(tester, 'Save');

    final note = container.read(notesProvider).single;
    expect(note.projectId, 'p1');
    expect(note.sourceSessionId, 's1');
    expect(note.sourceRepositoryId, 'r1');
    expect(
      note.sourceMessageOrdinal,
      isNull,
      reason: 'a terminal selection is not a message in a transcript',
    );
    expect(note.sourceMessageRole, isNull);
  });

  testWidgets('a plain shell tags nothing and invents nothing', (tester) async {
    final paneId = await pump(tester);
    await selectIn(tester, paneId, 'the failing line', to: 16);
    await openMenu(tester);
    await choose(tester, 'Create note from selection');
    await choose(tester, 'Save');

    final note = container.read(notesProvider).single;
    expect(note.projectId, isNull);
    expect(note.sourceSessionId, isNull);
    expect(note.sourceRepositoryId, isNull);
  });

  testWidgets('a todo taken in a session is filed under its project', (
    tester,
  ) async {
    final paneId = await pump(tester);
    runSessionIn(paneId);
    await selectIn(tester, paneId, 'fix the resize', to: 14);
    await openMenu(tester);
    await choose(tester, 'Create todo from selection');
    await choose(tester, 'Save');

    final todo = container.read(todosProvider).single;
    expect(todo.body, 'fix the resize');
    expect(todo.projectId, 'p1');
  });

  testWidgets('a todo from a plain shell is filed under nothing', (
    tester,
  ) async {
    final paneId = await pump(tester);
    await selectIn(tester, paneId, 'fix the resize', to: 14);
    await openMenu(tester);
    await choose(tester, 'Create todo from selection');
    await choose(tester, 'Save');

    expect(container.read(todosProvider).single.projectId, isNull);
  });

  testWidgets('a multi-line selection becomes one line, and the composer '
      'says so before it is saved', (tester) async {
    final paneId = await pump(tester);
    await selectIn(tester, paneId, 'alpha  beta\r\ngamma', to: 5, row: 1);
    await openMenu(tester);
    await choose(tester, 'Create todo from selection');

    // The collapse is on screen, in the field, before anything is written.
    expect(find.textContaining('2 lines'), findsOneWidget);
    await choose(tester, 'Save');

    final todo = container.read(todosProvider).single;
    expect(todo.body, 'alpha beta gamma');
    expect(todo.body, isNot(contains('\n')));
  });

  testWidgets('a note from the same selection keeps both lines', (
    tester,
  ) async {
    final paneId = await pump(tester);
    await selectIn(tester, paneId, 'alpha  beta\r\ngamma', to: 5, row: 1);
    await openMenu(tester);
    await choose(tester, 'Create note from selection');
    await choose(tester, 'Save');

    final note = container.read(notesProvider).single;
    expect(note.body, contains('alpha  beta'));
    expect(note.body, contains('\n'));
  });

  testWidgets('cancelling the composer writes nothing', (tester) async {
    final paneId = await pump(tester);
    await selectIn(tester, paneId, 'fix the resize', to: 14);
    await openMenu(tester);
    await choose(tester, 'Create todo from selection');
    await choose(tester, 'Cancel');

    expect(container.read(todosProvider), isEmpty);
  });
}
