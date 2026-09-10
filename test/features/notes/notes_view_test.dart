import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/notes/application/composer_draft.dart';
import 'package:karmashala/src/features/notes/application/notes_providers.dart';
import 'package:karmashala/src/features/notes/presentation/note_edit_dialog.dart';
import 'package:karmashala/src/features/notes/presentation/notes_view.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';

import '../terminal/fake_instance.dart';
import '../../support/fixtures.dart';

void main() {
  /// The panel this lives in, at the width it actually gets on a desktop.
  ///
  /// [platform] is what decides the density — a mouse or a thumb — and so
  /// whether a card's `⋮` is drawn at rest. Windows by default; the
  /// companion runs this pane on Android.
  Future<ProviderContainer> pump(
    WidgetTester tester, {
    bool withSession = true,
    TargetPlatform platform = TargetPlatform.windows,
  }) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    if (withSession) {
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      ProjectDao(db).insert(project());
      RepositoryDao(db).insert(repository());
      AgentInstallationDao(db).insert(agentInstallation());
    }
    // Faked terminals, because a Send with nothing selected resolves through
    // `focusedSessionIdProvider` and so reaches the real controller — whose
    // autosave timer would outlive the tree. Same overrides the Todos row's
    // send test takes, for the same reason.
    final container = ProviderContainer(
      overrides: fakeTerminalOverrides(database: db),
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
        child: MaterialApp(
          theme: AppTheme.light().copyWith(platform: platform),
          // Exactly what a root does: ask the platform, install the density.
          builder: (context, inner) => UiDensity.wrap(context, inner!),
          home: const Scaffold(
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

  /// Puts a mouse on [finder] and leaves it there.
  Future<TestGesture> hover(WidgetTester tester, Finder finder) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(() => gesture.removePointer());
    await gesture.moveTo(tester.getCenter(finder));
    await tester.pumpAndSettle();
    return gesture;
  }

  /// Opens a card's menu the way a mouse does: hover the card, then press the
  /// `⋮` the hover just revealed, then pick [choice].
  Future<void> pickFromRowMenu(
    WidgetTester tester,
    String title,
    String choice,
  ) async {
    // `.first` because a short note's title and its body are the same run of
    // text, drawn twice on the one card.
    await hover(tester, find.text(title).first);
    await tester.tap(find.byTooltip('Actions for “$title”'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(choice));
    await tester.pumpAndSettle();
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

    await pickFromRowMenu(tester, 'first draft', 'Edit note');
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

    await pickFromRowMenu(tester, 'never mind', 'Delete note');

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

    await tester.tap(find.byTooltip('Send to Toolbar rework'));
    await tester.pumpAndSettle();

    expect(
      container.read(composerDraftProvider),
      containsPair('s1', 'compact tab strip, please'),
    );
    // And that session is brought up, so the box is the one on screen.
    expect(container.read(selectedSessionIdProvider), 's1');
  });

  /// A note written in the panel does not name a target and does not watch one
  /// — the button is offered, and the click resolves it. See
  /// `notes_view_cost_test.dart` for what that buys the panel.
  testWidgets('a note with no session of its own goes to the active one', (
    tester,
  ) async {
    final container = await pump(tester);
    container.read(selectedSessionIdProvider.notifier).select('s1');
    container.read(notesProvider.notifier).capture(body: 'written here');
    await tester.pumpAndSettle();

    expect(find.text('Written here'), findsOneWidget);
    // Generic on purpose: the card cannot name a session it never read.
    await tester.tap(
      find.byTooltip('Send to the active session'),
    );
    await tester.pumpAndSettle();

    expect(
      container.read(composerDraftProvider),
      containsPair('s1', 'written here'),
    );
    // And the snackbar names where it actually landed — which here is
    // *nowhere yet*. This asserted "Sent to Toolbar rework’s message box."
    // until 2026-09-07, and that sentence was false for this exact setup:
    // s1 runs in no pane, so the workbench has mounted no conversation for it
    // and there is no composer for the note to appear in. The draft does wait
    // (`ComposerDrafts` is built for that) and lands when the session comes
    // up, so the honest report is that it is waiting, not that it arrived.
    // The case where it really does arrive is the next test.
    expect(
      find.text('Waiting for Toolbar rework — no terminal is running it.'),
      findsOneWidget,
    );
  });

  /// **Follow the face that is already showing.**
  ///
  /// `e7adebe6` made Send reveal the conversation, which fixed the text
  /// vanishing (`bb4283f0` had stopped the workbench mounting a composer
  /// nobody had asked for) by forcing the chat face open — whether or not that
  /// was where the user was working. The owner's rule is the narrower one:
  /// terminal showing, the text goes to the terminal; chat showing, it goes to
  /// the composer. So this file's reveal assertions are inverted here and in
  /// the test below: the group's face is now what Send *reads*, never what it
  /// writes.
  ///
  /// Typed and left there, the way a snippet is — [insertSnippet] is the path,
  /// and it never presses Enter in a pane, because a carriage return there
  /// takes a turn as if the user had.
  testWidgets('a note offered to a session showing its terminal is typed into '
      'the terminal', (tester) async {
    final container = await pump(tester);
    final terminals = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    terminals.openTab(TerminalProfile.powerShell);
    final paneId = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .focusedPaneId;
    container.read(sessionDaoProvider).updatePaneId('s1', paneId);
    final groupId = terminals.groupOfPane(paneId);
    expect(groupId, isNotNull);
    final written = <String>[];
    terminals.instanceFor(paneId)!.terminal.onOutput = written.add;

    container.read(notesProvider.notifier).capture(body: 'written here');
    await tester.pumpAndSettle();
    await tester.tap(
      find.byTooltip('Send to the active session'),
    );
    await tester.pumpAndSettle();

    // The bytes the pane would have handed its process: the note, and no
    // carriage return after it.
    expect(written, ['written here']);
    expect(
      container.read(composerDraftProvider).containsKey('s1'),
      isFalse,
      reason: 'a draft as well would deliver the same note twice',
    );
    expect(
      container.read(terminalVisibleInGroupProvider(groupId!)),
      isTrue,
      reason: 'the face the user was working in is the one that stays up',
    );
    expect(
      find.text('Typed into Toolbar rework’s terminal, unsent.'),
      findsOneWidget,
    );
  });

  /// The other half of the same rule — and the case `bb4283f0` broke, which is
  /// now answered by *reading* the face instead of forcing it.
  testWidgets('a note offered to a session showing its chat is queued for the '
      'composer', (tester) async {
    final container = await pump(tester);
    final terminals = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    terminals.openTab(TerminalProfile.powerShell);
    final paneId = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .focusedPaneId;
    container.read(sessionDaoProvider).updatePaneId('s1', paneId);
    final groupId = terminals.groupOfPane(paneId)!;
    terminals.showFaceIn(groupId, terminal: false);
    final written = <String>[];
    terminals.instanceFor(paneId)!.terminal.onOutput = written.add;

    container.read(notesProvider.notifier).capture(body: 'written here');
    await tester.pumpAndSettle();
    await tester.tap(
      find.byTooltip('Send to the active session'),
    );
    await tester.pumpAndSettle();

    expect(
      container.read(composerDraftProvider),
      containsPair('s1', 'written here'),
    );
    expect(written, isEmpty, reason: 'nothing was typed at the prompt');
    expect(
      container.read(terminalVisibleInGroupProvider(groupId)),
      isFalse,
      reason: 'still the chat, because that is where the user already was',
    );
    expect(find.text('Sent to Toolbar rework’s message box.'), findsOneWidget);
  });

  testWidgets('with nothing open, the click says so rather than the button', (
    tester,
  ) async {
    final container = await pump(tester, withSession: false);
    container.read(notesProvider.notifier).capture(body: 'someday');
    await tester.pumpAndSettle();

    final send = find.byTooltip('Send to the active session');
    expect(send, findsOneWidget);
    // Enabled: disabling on state the card refuses to watch is not possible,
    // and "just give the option" is the ask anyway.
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(of: send, matching: find.byType(IconButton)).first,
          )
          .onPressed,
      isNotNull,
    );

    await tester.tap(send);
    await tester.pumpAndSettle();

    expect(
      find.text('No session to send this to — open one first.'),
      findsOneWidget,
    );
    expect(container.read(composerDraftProvider), isEmpty);
  });

  /// The same rule the Todos pane and the Explorer keep: a card's actions are
  /// on the card, four ways in, and the `⋮` that duplicates them is drawn
  /// while a pointer or the keyboard is on it.
  ///
  /// Send is the exception and stays drawn. A note exists to be handed back to
  /// an agent; hiding the verb the surface is *for* would trade clutter for a
  /// worse problem, which is the trade `ExplorerRowAction` already refused.
  group('the card menu, four ways in', () {
    testWidgets('send stays; edit and delete are behind the menu', (
      tester,
    ) async {
      final container = await pump(tester);
      container
          .read(notesProvider.notifier)
          .capture(body: 'at rest', sourceSessionId: 's1');
      await tester.pumpAndSettle();

      expect(
        find.byTooltip('Send to Toolbar rework'),
        findsOneWidget,
      );
      expect(find.byTooltip('Actions for “at rest”'), findsNothing);

      await hover(tester, find.text('at rest').first);
      expect(find.byTooltip('Actions for “at rest”'), findsOneWidget);
    });

    testWidgets('the menu is always drawn on a touch surface', (tester) async {
      final container = await pump(tester, platform: TargetPlatform.android);
      container.read(notesProvider.notifier).capture(body: 'thumbed');
      await tester.pumpAndSettle();

      expect(find.byTooltip('Actions for “thumbed”'), findsOneWidget);
    });

    testWidgets('a right-click opens it', (tester) async {
      final container = await pump(tester);
      container.read(notesProvider.notifier).capture(body: 'right-clicked');
      await tester.pumpAndSettle();

      await tester.tap(
        find.text('right-clicked').first,
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();

      expect(find.text('Delete note'), findsOneWidget);
    });

    testWidgets('Shift+F10 opens it from the focused card', (tester) async {
      final container = await pump(tester);
      container.read(notesProvider.notifier).capture(body: 'keyboard only');
      await tester.pumpAndSettle();

      Focus.of(
        tester.element(find.text('keyboard only').first),
      ).requestFocus();
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      await tester.pumpAndSettle();

      expect(find.text('Delete note'), findsOneWidget);
    });

    testWidgets('so does the Menu key', (tester) async {
      final container = await pump(tester);
      container.read(notesProvider.notifier).capture(body: 'menu key');
      await tester.pumpAndSettle();

      Focus.of(tester.element(find.text('menu key').first)).requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();

      expect(find.text('Delete note'), findsOneWidget);
    });

    testWidgets(
      'and a note with nowhere to send still has a keyboard path to its menu',
      (tester) async {
        // The card body's tap target is the card's focus stop, and the only
        // way `Shift+F10` reaches the actions behind the `⋮` without a mouse.
        final container = await pump(tester, withSession: false);
        container.read(notesProvider.notifier).capture(body: 'someday');
        await tester.pumpAndSettle();

        Focus.of(tester.element(find.text('someday').first)).requestFocus();
        await tester.pumpAndSettle();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
        await tester.sendKeyEvent(LogicalKeyboardKey.f10);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
        await tester.pumpAndSettle();

        expect(find.text('Delete note'), findsOneWidget);
        // The menu is worded exactly as the button beside it — one verb, one
        // reading, whichever of the four ways in the user took.
        expect(
          find.text('Send to the active session'),
          findsOneWidget,
        );

        await tester.tap(find.text('Delete note'));
        await tester.pumpAndSettle();
        expect(container.read(notesProvider), isEmpty);
      },
    );

    testWidgets('the menu sends a note back, as the button does', (
      tester,
    ) async {
      final container = await pump(tester);
      container
          .read(notesProvider.notifier)
          .capture(body: 'from the menu', sourceSessionId: 's1');
      await tester.pumpAndSettle();

      await pickFromRowMenu(
        tester,
        'from the menu',
        'Send to Toolbar rework',
      );

      expect(
        container.read(composerDraftProvider),
        containsPair('s1', 'from the menu'),
      );
    });

    testWidgets('a mouse-driven choice is not swallowed by its own menu', (
      tester,
    ) async {
      // The Explorer's bug, asserted here so this pane cannot repeat it.
      final container = await pump(tester);
      container.read(notesProvider.notifier).capture(body: 'delete me');
      await tester.pumpAndSettle();

      final gesture = await hover(tester, find.text('delete me').first);
      await tester.tap(find.byTooltip('Actions for “delete me”'));
      await tester.pumpAndSettle();
      await gesture.moveTo(const Offset(1000, 500));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Delete note'));
      await tester.pumpAndSettle();

      expect(container.read(notesProvider), isEmpty);
    });

    testWidgets('tapping the card opens the editor', (tester) async {
      final container = await pump(tester);
      container.read(notesProvider.notifier).capture(body: 'tap to edit');
      await tester.pumpAndSettle();

      await tester.tap(find.text('tap to edit').first);
      await tester.pumpAndSettle();

      expect(find.byType(NoteEditDialog), findsOneWidget);
    });
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
