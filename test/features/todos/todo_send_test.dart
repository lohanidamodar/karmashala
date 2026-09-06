import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/theme/app_theme.dart';
import 'package:karmashala/src/app/theme/design_tokens.dart';
import 'package:karmashala/src/app/widgets/desktop_menu.dart';
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
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
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

  testWidgets('the row sends its line to the terminal tab on screen', (
    tester,
  ) async {
    await pump(tester);
    runSessionInATab('s1', title: 'Toolbar rework');
    container.read(todosProvider.notifier).add(body: 'Fix the resize');
    await tester.pumpAndSettle();

    await openRowMenu(tester, 'Fix the resize');
    await tester.tap(find.text('Send to Toolbar rework’s message box'));
    await tester.pumpAndSettle();

    // Offered, never dispatched: the box under the transcript is where it
    // lands, for the user to read and press Enter on.
    expect(container.read(composerDraftProvider)['s1'], 'Fix the resize');
    expect(container.read(selectedSessionIdProvider), 's1');
    // And the todo is still a todo. Sending is not ticking off.
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
    await tester.tap(find.text('Send to Second look’s message box'));
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
    final todos = container.read(todosProvider.notifier);
    todos.add(body: 'Fix the resize');
    todos.add(body: 'Then the strip');
    await tester.pumpAndSettle();

    await openRowMenu(tester, 'Fix the resize');
    await tester.tap(find.text('Send to Toolbar rework’s message box'));
    await tester.pumpAndSettle();
    await openRowMenu(tester, 'Then the strip');
    await tester.tap(find.text('Send to Toolbar rework’s message box'));
    await tester.pumpAndSettle();

    expect(
      container.read(composerDraftProvider)['s1'],
      'Fix the resize\n\nThen the strip',
    );
  });
}
