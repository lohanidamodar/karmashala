import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/shell_shortcuts.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/notes/application/note_drafts.dart';
import 'package:karmashala/src/features/notes/application/notes_providers.dart';
import 'package:karmashala/src/features/notes/presentation/note_tab_view.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_ui/code.dart';
import 'package:karmashala_ui/transcript.dart';

import '../../features/scale/scale_harness.dart';
import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **A note opens in a workbench tab of its own**, edited with the app's one
/// code editor and read as rendered markdown.
void main() {
  late CountingDatabase db;
  late FakeDataServer server;
  late DataClient data;

  setUp(() async {
    server = FakeDataServer();
    data = await server.connect();
    commandKeyIsMeta = false;
    db = CountingDatabase();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
  });
  tearDown(() => db.close());

  ProviderContainer shellContainer() {
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        dataClientProvider.overrideWithValue(data),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
  }

  Future<ProviderContainer> launch(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = shellContainer();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KarmashalaApp(),
      ),
    );
    await settle(tester);
    return container;
  }

  WidgetRef refOf(WidgetTester tester) =>
      tester.element(find.byType(WorkbenchView)) as WidgetRef;

  List<String> noteTabsIn(ProviderContainer container) => [
    for (final tab in container.read(terminalSessionsControllerProvider).tabs)
      if (tab.layout.panes.any(isNotePane)) tab.id,
  ];

  Future<void> openNotesPanel(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    container.read(sidePanelProvider.notifier).select(SidePanelSurface.notes);
    await settle(tester);
  }

  Future<void> typeBody(WidgetTester tester, String text) async {
    tester
            .widget<AppCodeEditor>(
              find.descendant(
                of: find.byType(NoteTabView),
                matching: find.byType(AppCodeEditor),
              ),
            )
            .controller
            .text =
        text;
    await tester.pump();
  }

  Finder inNote(Finder finder) =>
      find.descendant(of: find.byType(NoteTabView), matching: finder);

  Future<void> pressCommand(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
  }

  testWidgets('clicking a note opens its tab, and clicking again focuses it', (
    tester,
  ) async {
    final container = await launch(tester);
    container
        .read(notesProvider.notifier)
        .capture(body: 'Tab strip idea\n\nmore words');
    await openNotesPanel(tester, container);

    await tester.tap(find.text('Tab strip idea').first);
    await settle(tester);
    expect(find.byType(NoteTabView), findsOneWidget);
    expect(noteTabsIn(container), hasLength(1));
    final tabId = noteTabsIn(container).single;

    // Something else in front, then the same note again.
    container
        .read(terminalSessionsControllerProvider.notifier)
        .openTab(TerminalProfile.powerShell);
    await settle(tester);
    await tester.tap(find.text('Tab strip idea').first);
    await settle(tester);

    expect(noteTabsIn(container), [tabId]);
    expect(
      container.read(terminalSessionsControllerProvider).activeTabId,
      tabId,
    );
  });

  testWidgets('"Write a note" creates one and opens it, ready to type', (
    tester,
  ) async {
    final container = await launch(tester);
    await openNotesPanel(tester, container);

    await tester.tap(find.widgetWithText(FilledButton, 'Write a note'));
    await settle(tester);

    expect(container.read(notesProvider), hasLength(1));
    expect(noteTabsIn(container), hasLength(1));
    // A new note opens on the editor, not on an empty preview.
    expect(
      find.descendant(
        of: find.byType(NoteTabView),
        matching: find.byType(AppCodeEditor),
      ),
      findsOneWidget,
    );
  });

  testWidgets('an edit autosaves through the DAO and says so', (tester) async {
    final container = await launch(tester);
    final note = container.read(notesProvider.notifier).capture(body: 'draft');
    openNoteTab(refOf(tester), note.id);
    await settle(tester);
    await tester.tap(find.text('Edit'));
    await settle(tester);

    await typeBody(tester, 'draft, grown');
    expect(find.text('Saving…'), findsOneWidget);
    expect(server.notes[note.id]!.body, 'draft');

    await tester.pump(NoteDrafts.autosaveDelay);
    await settle(tester);
    expect(server.notes[note.id]!.body, 'draft, grown');
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('Ctrl+S saves at once and Ctrl+E toggles the preview', (
    tester,
  ) async {
    final container = await launch(tester);
    final note = container
        .read(notesProvider.notifier)
        .capture(body: '# Heading\n\nSome **bold** words');
    openNoteTab(refOf(tester), note.id);
    await settle(tester);

    // An existing note opens on its rendered preview.
    expect(find.byType(MarkdownMessage), findsOneWidget);
    expect(find.text('Heading'), findsOneWidget);

    await pressCommand(tester, LogicalKeyboardKey.keyE);
    expect(find.byType(MarkdownMessage), findsNothing);
    expect(
      find.descendant(
        of: find.byType(NoteTabView),
        matching: find.byType(AppCodeEditor),
      ),
      findsOneWidget,
    );

    await typeBody(tester, '# Heading\n\nchanged');
    await pressCommand(tester, LogicalKeyboardKey.keyS);
    expect(server.notes[note.id]!.body, '# Heading\n\nchanged');

    await pressCommand(tester, LogicalKeyboardKey.keyE);
    expect(
      tester.widget<MarkdownMessage>(inNote(find.byType(MarkdownMessage))).data,
      '# Heading\n\nchanged',
    );
  });

  testWidgets('the title is editable and names the tab', (tester) async {
    final container = await launch(tester);
    final note = container.read(notesProvider.notifier).capture(body: 'body');
    openNoteTab(refOf(tester), note.id);
    await settle(tester);

    await tester.enterText(
      find.descendant(
        of: find.byType(NoteTabView),
        matching: find.byType(TextField),
      ),
      'Compact tabs',
    );
    await tester.pump(NoteDrafts.autosaveDelay);
    await settle(tester);

    expect(server.notes[note.id]!.title, 'Compact tabs');
    final tabId = noteTabsIn(container).single;
    expect(
      container
          .read(terminalSessionsControllerProvider.notifier)
          .titleForTab(tabId),
      'Compact tabs',
    );
  });

  testWidgets('deleting from the tab asks, then closes the tab', (
    tester,
  ) async {
    final container = await launch(tester);
    final note = container.read(notesProvider.notifier).capture(body: 'bye');
    openNoteTab(refOf(tester), note.id);
    await settle(tester);

    await tester.tap(find.byTooltip('Delete note'));
    await settle(tester);
    expect(find.text('Delete note?'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Delete'),
      ),
    );
    await settle(tester);

    expect(server.notes[note.id], isNull);
    expect(noteTabsIn(container), isEmpty);
    expect(find.byType(NoteTabView), findsNothing);
  });

  testWidgets('a note deleted elsewhere closes its tab', (tester) async {
    final container = await launch(tester);
    final note = container.read(notesProvider.notifier).capture(body: 'x');
    openNoteTab(refOf(tester), note.id);
    await settle(tester);

    // What an agent's `note_delete` does.
    container.read(notesProvider.notifier).delete(note.id);
    await settle(tester);

    expect(noteTabsIn(container), isEmpty);
  });

  testWidgets('a change elsewhere refreshes the preview', (tester) async {
    final container = await launch(tester);
    final note = container.read(notesProvider.notifier).capture(body: 'old');
    openNoteTab(refOf(tester), note.id);
    await settle(tester);
    final preview = inNote(find.byType(MarkdownMessage));
    expect(tester.widget<MarkdownMessage>(preview).data, 'old');

    container.read(notesProvider.notifier).edit(note.id, body: 'new words');
    await settle(tester);

    expect(tester.widget<MarkdownMessage>(preview).data, 'new words');
  });

  testWidgets('a change elsewhere under unsaved edits is a notice, not an '
      'overwrite', (tester) async {
    final container = await launch(tester);
    final note = container.read(notesProvider.notifier).capture(body: 'base');
    openNoteTab(refOf(tester), note.id);
    await settle(tester);
    await tester.tap(find.text('Edit'));
    await settle(tester);

    await typeBody(tester, 'mine, unsaved');
    container.read(notesProvider.notifier).edit(note.id, body: 'theirs');
    await settle(tester);

    expect(find.textContaining('changed elsewhere'), findsWidgets);
    await tester.pump(NoteDrafts.autosaveDelay * 2);
    await settle(tester);
    expect(server.notes[note.id]!.body, 'theirs');

    await tester.tap(find.text('Keep mine'));
    await settle(tester);
    expect(server.notes[note.id]!.body, 'mine, unsaved');
  });

  testWidgets('closing a tab in conflict asks which to keep', (tester) async {
    final container = await launch(tester);
    final note = container.read(notesProvider.notifier).capture(body: 'base');
    openNoteTab(refOf(tester), note.id);
    await settle(tester);
    await tester.tap(find.text('Edit'));
    await settle(tester);
    await typeBody(tester, 'mine');
    container.read(notesProvider.notifier).edit(note.id, body: 'theirs');
    await settle(tester);

    await tester.tap(find.byTooltip('Unsaved changes — close tab'));
    await settle(tester);
    expect(find.text('Keep mine and close'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(noteTabsIn(container), hasLength(1));

    await tester.tap(find.byTooltip('Unsaved changes — close tab'));
    await settle(tester);
    await tester.tap(find.text('Keep mine and close'));
    await settle(tester);

    expect(noteTabsIn(container), isEmpty);
    expect(server.notes[note.id]!.body, 'mine');
  });

  testWidgets('closing an empty new note does not keep it', (tester) async {
    final container = await launch(tester);
    await openNotesPanel(tester, container);
    await tester.tap(find.widgetWithText(FilledButton, 'Write a note'));
    await settle(tester);
    expect(container.read(notesProvider), hasLength(1));

    await tester.tap(find.byTooltip('Close tab'));
    await settle(tester);

    expect(noteTabsIn(container), isEmpty);
    expect(container.read(notesProvider), isEmpty);
    expect(server.notes, isEmpty);
  });

  testWidgets('it comes back after a restart', (tester) async {
    final first = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        dataClientProvider.overrideWithValue(data),
      ],
    );
    final note = first.read(notesProvider.notifier).capture(body: 'kept');
    final terminals = first.read(terminalSessionsControllerProvider.notifier);
    terminals.openTab(TerminalProfile.powerShell);
    terminals.openDocumentTab(notePaneId(note.id));
    terminals.persistLayout();
    first.dispose();

    final container = await launch(tester);
    await settle(tester);

    expect(noteTabsIn(container), hasLength(1));
    container
        .read(terminalSessionsControllerProvider.notifier)
        .activateTab(noteTabsIn(container).single);
    await settle(tester);
    expect(find.byType(NoteTabView), findsOneWidget);
    expect(find.text('kept'), findsWidgets);
  });

  testWidgets('a restored tab whose note is gone closes', (tester) async {
    final first = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        dataClientProvider.overrideWithValue(data),
      ],
    );
    final terminals = first.read(terminalSessionsControllerProvider.notifier);
    terminals.openTab(TerminalProfile.powerShell);
    terminals.openDocumentTab(notePaneId('note-that-was-deleted'));
    terminals.persistLayout();
    first.dispose();

    final container = await launch(tester);
    await settle(tester);

    expect(noteTabsIn(container), isEmpty);
  });
}
