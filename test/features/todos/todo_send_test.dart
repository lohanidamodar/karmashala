import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/notes/application/composer_draft.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala/src/features/todos/application/todos_providers.dart';
import 'package:karmashala/src/features/todos/presentation/todos_view.dart';

import '../terminal/fake_instance.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// A todo's way back to a session.
///
/// A note is *sent back* by construction — it remembers the conversation it
/// was taken from. A todo remembers nothing, so its target has to be resolved
/// when the user asks, and the answer is [focusedSessionIdProvider]: the
/// Explorer's selection, and failing that the focused group's active tab.
/// That is already the one answer to "which session is this window about", and
/// a side panel inventing a second one is how two surfaces come to disagree.
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  Future<void> pump(WidgetTester tester) async {
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
      ],
    );
    addTearDown(container.dispose);

    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light().copyWith(platform: TargetPlatform.windows),
          builder: (context, inner) => UiDensity.wrap(context, inner!),
          home: const Scaffold(
            body: Row(
              children: [
                SizedBox(width: 320, child: TodosView()),
                Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Opens a terminal tab and runs session [id] in its pane.
  void runSessionInATab(String id, {required String title}) {
    final terminals = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    terminals.openTab(TerminalProfile.powerShell);
    final paneId = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .focusedPaneId;
    SessionDao(db)
      ..insert(session(id: id, title: title))
      ..updatePaneId(id, paneId);
  }

  /// The row menu, opened the way that needs no pointer bookkeeping: a
  /// right-click, which [RowContextMenu] answers exactly as the `⋮` does.
  Future<void> openRowMenu(WidgetTester tester, String body) async {
    await tester.tap(find.text(body), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
  }

  /// **Follow the face that is already showing.**
  ///
  /// Every assertion in this file used to check only that the draft was
  /// *queued*, which is why they stayed green from 2026-09-02 while
  /// `bb4283f0` left the text in a composer that was never mounted. `e7adebe6`
  /// answered that by making Send reveal the conversation, and asserted the
  /// reveal here — going one step too far: it forced the chat face open over
  /// whatever the user was working in. The owner's rule is narrower, and it is
  /// what these two tests pin: the face is what Send **reads**.
  ///
  /// Terminal showing, so the line is typed at the prompt and left there —
  /// [insertSnippet]'s contract, which never presses Enter in a pane.
  testWidgets('a todo offered to a session showing its terminal is typed into '
      'the terminal', (tester) async {
    await pump(tester);
    runSessionInATab('s1', title: 'Resize');
    await tester.pumpAndSettle();
    final terminals = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final paneId = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .focusedPaneId;
    final groupId = terminals.groupOfPane(paneId);
    expect(groupId, isNotNull, reason: 'the tab landed in a group');
    final written = <String>[];
    terminals.instanceFor(paneId)!.terminal.onOutput = written.add;

    container.read(todosProvider.notifier).add(body: 'Fix the resize');
    await tester.pumpAndSettle();
    await openRowMenu(tester, 'Fix the resize');
    await tester.tap(find.textContaining('Send to '));
    await tester.pumpAndSettle();

    expect(written, ['Fix the resize']);
    expect(
      container.read(composerDraftProvider).containsKey('s1'),
      isFalse,
      reason: 'the line went to the terminal; a draft too would send it twice',
    );
    expect(
      container.read(terminalVisibleInGroupProvider(groupId!)),
      isTrue,
      reason: 'the face the user was working in stays up',
    );
    expect(find.text('Typed into Resize’s terminal, unsent.'), findsOneWidget);
  });

  /// The other half: chat showing, so the line goes to the composer — and the
  /// face is still not written to.
  testWidgets('a todo offered to a session showing its chat is queued for the '
      'composer', (tester) async {
    await pump(tester);
    runSessionInATab('s1', title: 'Resize');
    await tester.pumpAndSettle();
    final terminals = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final paneId = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .focusedPaneId;
    final groupId = terminals.groupOfPane(paneId)!;
    terminals.showFaceIn(groupId, terminal: false);
    final written = <String>[];
    terminals.instanceFor(paneId)!.terminal.onOutput = written.add;

    container.read(todosProvider.notifier).add(body: 'Fix the resize');
    await tester.pumpAndSettle();
    await openRowMenu(tester, 'Fix the resize');
    await tester.tap(find.textContaining('Send to '));
    await tester.pumpAndSettle();

    expect(container.read(composerDraftProvider)['s1'], 'Fix the resize');
    expect(written, isEmpty);
    expect(container.read(terminalVisibleInGroupProvider(groupId)), isFalse);
    expect(find.text('Sent to Resize’s message box.'), findsOneWidget);
  });

  testWidgets('the row resolves the tab on screen, and sending is not '
      'ticking off', (tester) async {
    await pump(tester);
    runSessionInATab('s1', title: 'Toolbar rework');
    container.read(todosProvider.notifier).add(body: 'Fix the resize');
    await tester.pumpAndSettle();

    await openRowMenu(tester, 'Fix the resize');
    await tester.tap(find.text('Send to Toolbar rework'));
    await tester.pumpAndSettle();

    // Offered, never dispatched — whichever face it landed in. That tab shows
    // its terminal, so this asserts the destination nothing else does: the
    // session is brought up, and the row is still a row.
    expect(container.read(selectedSessionIdProvider), 's1');
    expect(container.read(todosProvider).single.isDone, isFalse);
  });

  testWidgets('an explicit Explorer selection wins over the tab on screen', (
    tester,
  ) async {
    await pump(tester);
    runSessionInATab('s1', title: 'Toolbar rework');
    SessionDao(db).insert(session(id: 's2', title: 'Second look'));
    container.read(selectedSessionIdProvider.notifier).select('s2');
    container.read(todosProvider.notifier).add(body: 'Fix the resize');
    await tester.pumpAndSettle();

    await openRowMenu(tester, 'Fix the resize');
    await tester.tap(find.text('Send to Second look'));
    await tester.pumpAndSettle();

    expect(container.read(composerDraftProvider)['s2'], 'Fix the resize');
    expect(container.read(composerDraftProvider).containsKey('s1'), isFalse);
  });

  testWidgets('with no session anywhere the row says so rather than '
      'pretending it would work', (tester) async {
    await pump(tester);
    container.read(todosProvider.notifier).add(body: 'Fix the resize');
    await tester.pumpAndSettle();

    await openRowMenu(tester, 'Fix the resize');

    expect(find.text('Send to a session — open one first'), findsOneWidget);
    final row = tester.widget<DesktopMenuItem<String>>(
      find.ancestor(
        of: find.text('Send to a session — open one first'),
        matching: find.byType(DesktopMenuItem<String>),
      ),
    );
    expect(row.enabled, isFalse);
  });

  testWidgets('a second send appends rather than replacing the first', (
    tester,
  ) async {
    await pump(tester);
    runSessionInATab('s1', title: 'Toolbar rework');
    // In the chat face, because that is the one `ComposerDrafts` serves: a
    // group showing its terminal is typed into instead, and never queues.
    final terminals = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final paneId = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .focusedPaneId;
    terminals.showFaceIn(terminals.groupOfPane(paneId)!, terminal: false);
    final todos = container.read(todosProvider.notifier);
    todos.add(body: 'Fix the resize');
    todos.add(body: 'Then the strip');
    await tester.pumpAndSettle();

    await openRowMenu(tester, 'Fix the resize');
    await tester.tap(find.text('Send to Toolbar rework'));
    await tester.pumpAndSettle();
    await openRowMenu(tester, 'Then the strip');
    await tester.tap(find.text('Send to Toolbar rework'));
    await tester.pumpAndSettle();

    expect(
      container.read(composerDraftProvider)['s1'],
      'Fix the resize\n\nThen the strip',
    );
  });
}
