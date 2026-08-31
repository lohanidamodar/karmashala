import 'package:chitragupta/src/app/shell/quick_open/quick_open.dart';
import 'package:chitragupta/src/app/shell/tab_picker.dart';
import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/git/application/changes_providers.dart';
import 'package:chitragupta/src/features/github/application/github_providers.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/sessions/data/session_dao.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:chitragupta/src/features/terminal/domain/terminal_profile.dart';
import 'package:chitragupta/src/features/sessions/application/session_ui_providers.dart';
import 'package:chitragupta/src/features/projects/application/projects_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../features/terminal/fake_instance.dart';
import '../../../support/fakes.dart';
import '../../../support/fixtures.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    ProjectDao(db).insert(project(name: 'Chitragupta'));
    RepositoryDao(db).insert(repository(name: 'app'));
    AgentInstallationDao(db).insert(agentInstallation());
    SessionDao(db)
      ..insert(session(id: 's1', title: 'Fix login redirect'))
      ..insert(session(id: 's2', title: 'Write the release notes'));
  });
  tearDown(() => db.close());

  /// Opens the palette. [before] runs once the workspace is selected and
  /// before the palette builds its items — which is when anything it has to
  /// find already has to exist.
  Future<ProviderContainer> open(
    WidgetTester tester, {
    void Function(ProviderContainer container)? before,
  }) async {
    final container = ProviderContainer(
      overrides: fakeTerminalOverrides(database: db),
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => QuickOpen.show(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    // A repository has to be selected for the file/branch sources to have a
    // subject; the shell selects one as soon as a project is picked.
    container.read(selectedProjectIdProvider.notifier).select('p1');
    container.read(selectedRepositoryIdProvider.notifier).select('r1');
    before?.call(container);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> type(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.pumpAndSettle();
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  testWidgets('opens grouped, with sessions and commands under headers', (
    tester,
  ) async {
    await open(tester);

    // Sessions lead an empty query: the recent work is what a workspace
    // launcher is usually opened to reach.
    expect(find.text('SESSIONS'), findsOneWidget);
    expect(find.text('Fix login redirect'), findsOneWidget);
    // Every session names where it lives, so two sessions called "Fix" in
    // different repositories are still told apart.
    expect(find.textContaining('Chitragupta · app'), findsWidgets);
    // Projects and repositories are their own group, not sessions.
    expect(find.text('PROJECTS & REPOSITORIES'), findsOneWidget);
  });

  testWidgets('a command is found by name, under its own header', (
    tester,
  ) async {
    await open(tester);

    await type(tester, 'settings');

    expect(find.text('COMMANDS'), findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);
  });

  testWidgets('Enter opens the session the query ranked first', (tester) async {
    final container = await open(tester);

    await type(tester, 'login');
    await press(tester, LogicalKeyboardKey.enter);

    expect(container.read(selectedSessionIdProvider), 's1');
    expect(container.read(selectedRepositoryIdProvider), 'r1');
    // It closed behind itself.
    expect(find.byType(QuickOpen), findsNothing);
  });

  /// Opens quick open, lists only the two sessions, runs [drive], and reports
  /// which session Enter actually opened.
  ///
  /// Comparing two runs is what makes a navigation test mean something: an
  /// assertion that *something* was selected passes just as well when the
  /// arrows do nothing at all, which is exactly the bug this exists to catch.
  Future<String?> sessionAfter(
    WidgetTester tester,
    Future<void> Function() drive,
  ) async {
    final container = await open(tester);
    await type(tester, '#');
    await drive();
    await press(tester, LogicalKeyboardKey.enter);
    return container.read(selectedSessionIdProvider);
  }

  testWidgets('Down moves the selection off the first result', (tester) async {
    final first = await sessionAfter(tester, () async {});
    final second = await sessionAfter(
      tester,
      () => press(tester, LogicalKeyboardKey.arrowDown),
    );

    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(second, isNot(first));
  });

  testWidgets('Up comes back, and stops at the top', (tester) async {
    final first = await sessionAfter(tester, () async {});
    final backAgain = await sessionAfter(tester, () async {
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowUp);
      // Already at the top: this must not wrap round to the bottom.
      await press(tester, LogicalKeyboardKey.arrowUp);
    });

    expect(backAgain, first);
  });

  testWidgets('Ctrl+N and Ctrl+P move as the arrows do', (tester) async {
    Future<void> ctrl(LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    final first = await sessionAfter(tester, () async {});
    final next = await sessionAfter(
      tester,
      () => ctrl(LogicalKeyboardKey.keyN),
    );
    final backAgain = await sessionAfter(tester, () async {
      await ctrl(LogicalKeyboardKey.keyN);
      await ctrl(LogicalKeyboardKey.keyP);
    });

    expect(next, isNot(first));
    expect(backAgain, first);
  });

  testWidgets('End jumps to the last result and Home back to the first', (
    tester,
  ) async {
    final first = await sessionAfter(tester, () async {});
    final last = await sessionAfter(
      tester,
      () => press(tester, LogicalKeyboardKey.end),
    );
    final backAgain = await sessionAfter(tester, () async {
      await press(tester, LogicalKeyboardKey.end);
      await press(tester, LogicalKeyboardKey.home);
    });

    expect(last, isNot(first));
    expect(backAgain, first);
  });

  testWidgets('typing keeps the caret in the field while the arrows move', (
    tester,
  ) async {
    await open(tester);
    await type(tester, '#');
    await press(tester, LogicalKeyboardKey.arrowDown);

    // The arrows drive the list, so they must not have moved the caret or
    // stolen focus: the next character still lands in the query.
    await tester.enterText(find.byType(TextField), '#release');
    await tester.pumpAndSettle();

    expect(find.text('Write the release notes'), findsOneWidget);
    expect(find.text('Fix login redirect'), findsNothing);
  });

  testWidgets('a new query resets the selection to the top', (tester) async {
    final container = await open(tester);

    await type(tester, '#');
    await press(tester, LogicalKeyboardKey.arrowDown);
    // Re-filtering to one result must not leave the highlight on a row that
    // is no longer there.
    await type(tester, '#login');
    await press(tester, LogicalKeyboardKey.enter);

    expect(container.read(selectedSessionIdProvider), 's1');
  });

  testWidgets('Escape closes it without opening anything', (tester) async {
    final container = await open(tester);

    await type(tester, '#');
    await press(tester, LogicalKeyboardKey.escape);

    expect(find.byType(QuickOpen), findsNothing);
    expect(container.read(selectedSessionIdProvider), isNull);
  });

  testWidgets('a > query lists commands and nothing else', (tester) async {
    await open(tester);

    await type(tester, '>settings');

    expect(find.text('COMMANDS'), findsOneWidget);
    expect(find.text('SESSIONS'), findsNothing);
    expect(find.text('Open Settings'), findsOneWidget);
  });

  testWidgets('a query that matches nothing says so', (tester) async {
    await open(tester);

    await type(tester, 'zzzzqqqq');

    expect(find.text('Nothing matches.'), findsOneWidget);
  });

  testWidgets('a terminal tab of its own is findable by its directory', (
    tester,
  ) async {
    // A shell, a build or a dev server has no session row pointing at it, so
    // before this it had no entry in quick open at all — and at a hundred open
    // tabs the strip is not a way to reach one by name.
    late String wanted;
    final container = await open(tester, before: (container) {
      final terminals = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      wanted = terminals.openTab(
        TerminalProfile.powerShell,
        workingDirectory: r'C:\src\dev-server',
      );
      terminals.openTab(
        TerminalProfile.powerShell,
        workingDirectory: r'C:\src\something-else',
      );
    });

    // Both tabs are called PowerShell; the directory is the only thing that
    // tells them apart, so it is what the query has to be able to reach.
    await type(tester, 'dev-server');
    expect(find.text('OPEN TABS'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.enter);

    expect(
      container.read(terminalSessionsControllerProvider).activeTabId,
      wanted,
    );
    expect(container.read(terminalVisibleProvider), isTrue);
  });

  testWidgets('a tab running one of our sessions is not listed twice', (
    tester,
  ) async {
    // Picking the session already reattaches and focuses its pane, so a tab
    // entry beside it would be the same destination in the list twice.
    await open(tester, before: (container) {
      final terminals = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      terminals.openTab(TerminalProfile.powerShell);
      SessionDao(db).updatePaneId(
        's1',
        container
            .read(terminalSessionsControllerProvider)
            .tabs
            .single
            .focusedPaneId,
      );
    });

    expect(find.text('SESSIONS'), findsOneWidget);
    expect(find.text('OPEN TABS'), findsNothing);
  });

  testWidgets('a command opens the picker with every tab in it', (
    tester,
  ) async {
    // The tabs quick open lists itself are only the ones that are *nothing
    // but* tabs, and reaching one that way means already knowing its name.
    // This is the other question — "show me my tabs" — and it hands over to
    // the strip's own picker rather than growing a second one.
    await open(tester, before: (container) {
      final terminals = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      terminals.openTab(TerminalProfile.powerShell);
      SessionDao(db).updatePaneId(
        's1',
        container
            .read(terminalSessionsControllerProvider)
            .tabs
            .single
            .focusedPaneId,
      );
      terminals.openTab(
        TerminalProfile.powerShell,
        workingDirectory: r'C:\src\dev-server',
      );
    });

    await type(tester, 'switch terminal tab');
    await tester.tap(find.text('Switch terminal tab…'));
    await tester.pumpAndSettle();

    expect(find.byType(TabPicker), findsOneWidget);
    // Both of them, including the one running a session — which quick open's
    // own list leaves out because the session already stands for it.
    expect(find.text('2 tabs'), findsOneWidget);
    expect(find.textContaining('Fix login redirect'), findsOneWidget);
  });

  testWidgets('opening it never starts a network or git call', (tester) async {
    final container = await open(tester);
    await type(tester, 'login');

    // The GitHub and git providers run `gh` and `git`; quick open reads them
    // only when something else has already brought them to life.
    expect(container.exists(githubPullRequestsProvider), isFalse);
    expect(container.exists(githubIssuesProvider), isFalse);
    expect(container.exists(repositoryChangesProvider), isFalse);
    expect(container.exists(repoWorktreesProvider), isFalse);
  });
}
