import 'dart:io';

import 'package:karmashala/src/app/shell/quick_open/quick_open.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';
import 'package:karmashala/src/features/overview/application/overview_resume.dart';
import 'package:karmashala/src/app/shell/quick_open/quick_open_list.dart';
import 'package:karmashala/src/app/shell/tab_picker.dart';
import 'package:karmashala/src/features/automations/application/scheduled_resume_providers.dart';
import 'package:karmashala/src/features/automations/presentation/resume_on_reset_dialog.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/github/application/github_providers.dart';
import 'package:karmashala/src/features/explorer/application/explorer_actions.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../features/terminal/fake_instance.dart';
import '../../../support/fakes.dart';
import '../../../support/fixtures.dart';
import '../../../support/fake_data_server.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import '../../../support/test_machine.dart';
import 'package:agent_cli/process.dart';

void main() {
  late TestMachine db;
  late FakeDataServer server;
  late Override data;
  late _SpyResumer resumer;

  /// The session a pick showed: in the dashboard's peek with the background
  /// setting on, selected in the lists with it off.
  String? shown(ProviderContainer container) =>
      container.read(overviewFocusProvider).peeked ??
      container.read(selectedSessionIdProvider);

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    data = await server.override();
    server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
    server.projectRows.insert(project(name: 'Karmashala'));
    server.repositoryRows.insert(repository(name: 'app'));
    server.installationRows.insert(agentInstallation());
    db.server.sessionRows
      ..insert(session(id: 's1', title: 'Fix login redirect'))
      ..insert(session(id: 's2', title: 'Write the release notes'));
  });

  /// Opens the palette. [before] runs once the workspace is selected and
  /// before the palette builds its items — which is when anything it has to
  /// find already has to exist.
  Future<ProviderContainer> open(
    WidgetTester tester, {
    void Function(ProviderContainer container)? before,
    // A factory rather than a list of overrides: `Override` is not a nameable
    // type here, which is the same reason `fakeTerminalOverrides` leaves its
    // own return type inferred.
    ExplorerActions Function(Ref ref)? explorerActions,
    bool background = true,
  }) async {
    final prefs = Directory.systemTemp.createTempSync('ks-quick-open');
    addTearDown(() => prefs.deleteSync(recursive: true));
    final container = ProviderContainer(
      overrides: [
        data,
        ...fakeTerminalOverrides(machine: db),
        overviewPrefsDirectoryProvider.overrideWithValue(() async => prefs),
        overviewResumerProvider.overrideWith(_SpyResumer.new),
        if (explorerActions != null)
          explorerActionsProvider.overrideWith(explorerActions),
      ],
    );
    addTearDown(container.dispose);
    container
        .read(overviewPrefsProvider.notifier)
        .setLaunchInBackground(background);
    resumer = container.read(overviewResumerProvider) as _SpyResumer;
    // Built now, so a test holding the spy has it even when nothing opens.
    if (explorerActions != null) container.read(explorerActionsProvider);
    // The dashboard's peek lives while the dashboard is built; held here so
    // a session shown there can be read back.
    // Disposed with the container: closing it after the scope has gone is
    // refused.
    container.listen(overviewFocusProvider, (_, _) {});
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
    expect(find.textContaining('Karmashala · app'), findsWidgets);
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

  testWidgets('the log tail is a command that opens a tab', (tester) async {
    await open(tester);

    await type(tester, 'logs');

    expect(find.text('Open Logs'), findsOneWidget);
    // Not a context-panel surface any more: nothing else answers to it.
    expect(find.text('Logs'), findsNothing);
  });

  testWidgets('the dashboard keys are a command that shows them', (
    tester,
  ) async {
    await open(tester);

    await type(tester, 'dashboard keys');
    expect(find.text('Show Agent dashboard keys'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.enter);

    expect(find.byKey(const ValueKey('overview-keys')), findsOneWidget);
  });

  testWidgets('New session is offered with nothing selected', (tester) async {
    // It used to be hidden here, because the dialog it opens could only create
    // a session for the selected repository. The dialog picks its own
    // destination now — so the command is always available, and in a workspace
    // with no projects at all it is the dialog that says so.
    await open(
      tester,
      before: (container) {
        container.read(selectedRepositoryIdProvider.notifier).select(null);
        container.read(selectedProjectIdProvider.notifier).select(null);
      },
    );

    await type(tester, 'new session');

    expect(find.text('New session…'), findsOneWidget);
    // Fan out still needs one: it launches several agents into worktrees of a
    // repository, and it has no picker of its own yet.
    expect(find.text('Fan out prompt…'), findsNothing);
  });

  testWidgets('Enter opens the session the query ranked first', (tester) async {
    final container = await open(tester);

    await type(tester, 'login');
    await press(tester, LogicalKeyboardKey.enter);

    expect(shown(container), 's1');
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
    return shown(container);
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

  testWidgets('Down keeps the cursor in view at twice the text', (
    tester,
  ) async {
    // The rows grow with the text and so must the section headers, or every
    // header above the cursor puts the reveal arithmetic further out.
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await open(tester);
    final list = tester.getRect(find.byType(ListView));
    for (var step = 0; step < 30; step++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
      final row = tester.getRect(
        find.byWidgetPredicate((w) => w is QuickOpenRow && w.selected),
      );
      expect(row.top, greaterThanOrEqualTo(list.top), reason: 'step $step');
      expect(
        row.bottom,
        lessThanOrEqualTo(list.bottom + 0.5),
        reason: 'step $step',
      );
    }
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('End brings the last row into view at ${scale}x text', (
      tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await open(tester);
      await press(tester, LogicalKeyboardKey.end);

      final list = tester.getRect(find.byType(ListView));
      final row = find.byWidgetPredicate(
        (w) => w is QuickOpenRow && w.selected,
      );
      expect(row, findsOneWidget, reason: 'the last row was never built');
      expect(tester.getRect(row).bottom, lessThanOrEqualTo(list.bottom + 0.5));
    });
  }

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

    expect(shown(container), 's1');
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
    final container = await open(
      tester,
      before: (container) {
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
      },
    );

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

  testWidgets('with the background setting off, picking a session opens it, '
      'not just selects it', (tester) async {
    // The owner: "quick menu bataa session resume garda kina yesto aaucha?
    // kina sidhai resume hunna?" — picking a session by name landed on the
    // workbench's "No terminal of ours is running this session" screen with a
    // Resume button, having already been told which session was wanted.
    // Focusing selected the row and stopped; nothing ever opened it.
    late _SpyActions actions;
    final container = await open(
      tester,
      background: false,
      explorerActions: (ref) => actions = _SpyActions(ref),
    );
    await type(tester, '#');
    await press(tester, LogicalKeyboardKey.enter);

    expect(
      actions.opened,
      hasLength(1),
      reason: 'the pick reached the same action the Explorer click runs',
    );
    expect(actions.opened.single, container.read(selectedSessionIdProvider));
    expect(container.read(overviewFocusProvider).peeked, isNull);
  });

  group('a stopped session: shown, and resumed only when asked', () {
    // A resume sends the conversation back as context, which costs tokens;
    // picking a row is usually a look.
    testWidgets('setting on: Enter shows it in the dashboard\'s peek — no '
        'tab, no resume', (tester) async {
      late _SpyActions actions;
      final container = await open(
        tester,
        explorerActions: (ref) => actions = _SpyActions(ref),
      );
      await type(tester, 'login');
      await press(tester, LogicalKeyboardKey.enter);

      expect(container.read(overviewFocusProvider).peeked, 's1');
      expect(resumer.resumed, isEmpty);
      expect(actions.opened, isEmpty);
      expect(container.read(selectedSessionIdProvider), isNull);
    });

    testWidgets('setting on: Shift+Enter resumes it in the background', (
      tester,
    ) async {
      late _SpyActions actions;
      final container = await open(
        tester,
        explorerActions: (ref) => actions = _SpyActions(ref),
      );
      await type(tester, 'login');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();

      expect(resumer.resumed, ['s1']);
      expect(actions.opened, isEmpty);
      expect(container.read(overviewFocusProvider).peeked, 's1');
    });

    testWidgets("setting on: the row's Resume button resumes it", (
      tester,
    ) async {
      await open(tester);
      await type(tester, 'login');
      await tester.tap(find.byKey(const ValueKey('quick-open-resume')));
      await tester.pumpAndSettle();

      expect(resumer.resumed, ['s1']);
    });

    testWidgets('setting off: Shift+Enter resumes it into its tab', (
      tester,
    ) async {
      late _SpyActions actions;
      await open(
        tester,
        background: false,
        explorerActions: (ref) => actions = _SpyActions(ref),
      );
      await type(tester, 'login');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();

      expect(actions.opened, ['s1']);
      expect(resumer.resumed, isEmpty);
    });
  });

  testWidgets('a tab running one of our sessions is not listed twice', (
    tester,
  ) async {
    // Picking the session already reattaches and focuses its pane, so a tab
    // entry beside it would be the same destination in the list twice.
    await open(
      tester,
      before: (container) {
        final terminals = container.read(
          terminalSessionsControllerProvider.notifier,
        );
        terminals.openTab(TerminalProfile.powerShell);
        db.server.sessionRows.updatePaneId(
          's1',
          container
              .read(terminalSessionsControllerProvider)
              .tabs
              .single
              .focusedPaneId,
        );
      },
    );

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
    await open(
      tester,
      before: (container) {
        final terminals = container.read(
          terminalSessionsControllerProvider.notifier,
        );
        terminals.openTab(TerminalProfile.powerShell);
        db.server.sessionRows.updatePaneId(
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
      },
    );

    await type(tester, 'switch terminal tab');
    await tester.tap(find.text('Switch terminal tab…'));
    await tester.pumpAndSettle();

    expect(find.byType(TabPicker), findsOneWidget);
    // Both of them, including the one running a session — which quick open's
    // own list leaves out because the session already stands for it.
    expect(find.text('2 tabs'), findsOneWidget);
    expect(find.textContaining('Fix login redirect'), findsOneWidget);
  });

  testWidgets('the palette is the keyboard\'s way into and out of a group', (
    tester,
  ) async {
    // Splitting the workspace leaves an empty group and dragging a tab into it
    // is a mouse gesture; this command is the same verb without one. A feature
    // reachable only by dragging is one some people cannot reach at all.
    late ProviderContainer scope;
    await open(
      tester,
      before: (container) {
        scope = container;
        final terminals = container.read(
          terminalSessionsControllerProvider.notifier,
        );
        terminals.openTab(TerminalProfile.powerShell);
        terminals.openTab(
          TerminalProfile.powerShell,
          workingDirectory: r'C:\src\dev-server',
        );
        terminals.splitWorkspace(SplitAxis.horizontal);
      },
    );

    await type(tester, 'move a tab into');
    await tester.tap(find.text('Move a tab into the empty group…'));
    await tester.pumpAndSettle();

    expect(find.byType(TabPicker), findsOneWidget);
    expect(find.text('2 tabs'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.enter);

    final state = scope.read(terminalSessionsControllerProvider);
    expect(state.tabs, hasLength(2), reason: 'a tab moved, none was consumed');
    expect(state.workspace!.groups, hasLength(2));
  });

  testWidgets('and the empty region one level down takes a pane', (
    tester,
  ) async {
    // A region holds panes; a group holds tabs. Two structures, two commands,
    // and the titles say which — see `WorkspaceLayout`.
    late ProviderContainer scope;
    await open(
      tester,
      before: (container) {
        scope = container;
        final terminals = container.read(
          terminalSessionsControllerProvider.notifier,
        );
        terminals.openTab(TerminalProfile.powerShell);
        terminals.splitPaneWith(
          SplitAxis.horizontal,
          TerminalProfile.powerShell,
        );
        terminals.splitPane(SplitAxis.vertical);
      },
    );

    await type(tester, 'move a pane into');
    await tester.tap(find.text('Move a pane into the empty region…'));
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.enter);

    final state = scope.read(terminalSessionsControllerProvider);
    expect(state.tabs, hasLength(1), reason: 'no tab was consumed');
    final layout = state.activeTab!.layout;
    // The pane filled the room, so the region it left collapsed and the slot
    // id retired with it: two regions, two real panes.
    expect(layout.groups, hasLength(2));
    expect(layout.panes, hasLength(2));
  });

  testWidgets('and it moves a pane from one region into another', (
    tester,
  ) async {
    late ProviderContainer scope;
    await open(
      tester,
      before: (container) {
        scope = container;
        final terminals = container.read(
          terminalSessionsControllerProvider.notifier,
        );
        terminals.openTab(TerminalProfile.powerShell);
        terminals.splitPaneWith(
          SplitAxis.horizontal,
          TerminalProfile.powerShell,
        );
        terminals.splitPaneWith(SplitAxis.vertical, TerminalProfile.powerShell);
      },
    );

    await type(tester, 'move this pane into');
    await tester.tap(find.text('Move this pane into another region…'));
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.enter);

    final layout = scope
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .layout;
    expect(layout.groups, hasLength(2), reason: 'the region it left collapsed');
    expect(layout.panes, hasLength(3));
  });

  testWidgets('and it offers the way back out of one', (tester) async {
    late ProviderContainer scope;
    await open(
      tester,
      before: (container) {
        scope = container;
        final terminals = container.read(
          terminalSessionsControllerProvider.notifier,
        );
        terminals.openTab(TerminalProfile.powerShell);
        terminals.splitPaneWith(
          SplitAxis.horizontal,
          TerminalProfile.powerShell,
        );
      },
    );

    await type(tester, 'move this pane');
    await tester.tap(find.text('Move this pane to a new tab'));
    await tester.pumpAndSettle();

    final state = scope.read(terminalSessionsControllerProvider);
    expect(state.tabs, hasLength(2), reason: 'the pane took a tab of its own');
    for (final tab in state.tabs) {
      expect(tab.layout.panes, hasLength(1));
    }
  });

  testWidgets('an empty group is offered the same two splits', (tester) async {
    late ProviderContainer scope;
    await open(
      tester,
      before: (container) {
        scope = container;
        container.read(terminalSessionsControllerProvider.notifier)
          ..openTab(TerminalProfile.powerShell)
          ..splitWorkspace(SplitAxis.horizontal);
      },
    );

    await type(tester, 'split the workspace');
    expect(find.text('Split the workspace right'), findsOneWidget);
    await tester.tap(find.text('Split the workspace down'));
    await tester.pumpAndSettle();

    final state = scope.read(terminalSessionsControllerProvider);
    expect(state.workspace!.groups, hasLength(3));
    expect(state.tabs, hasLength(1));
  });

  testWidgets('a split the group has no room for is left off the list', (
    tester,
  ) async {
    await open(
      tester,
      before: (container) {
        final terminals = container.read(
          terminalSessionsControllerProvider.notifier,
        )..openTab(TerminalProfile.powerShell);
        for (var i = 0; i < 4; i++) {
          terminals.splitWorkspace(SplitAxis.horizontal);
        }
      },
    );

    await type(tester, 'split the workspace');

    expect(find.text('Split the workspace right'), findsNothing);
    expect(find.text('Split the workspace down'), findsOneWidget);
  });

  testWidgets('with several empty groups a tab moves into the focused one', (
    tester,
  ) async {
    late ProviderContainer scope;
    late String first;
    late String second;
    await open(
      tester,
      before: (container) {
        scope = container;
        final terminals = container.read(
          terminalSessionsControllerProvider.notifier,
        );
        terminals.openTab(TerminalProfile.powerShell);
        terminals.openTab(TerminalProfile.powerShell);
        first = terminals.splitWorkspace(SplitAxis.horizontal)!;
        second = terminals.splitWorkspace(SplitAxis.vertical)!;
      },
    );

    await type(tester, 'move a tab into');
    await tester.tap(find.text('Move a tab into the empty group…'));
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.enter);

    final terminals = scope.read(terminalSessionsControllerProvider.notifier);
    expect(terminals.tabsInGroup(second), hasLength(1));
    expect(terminals.isEmptyGroup(first), isTrue);
  });

  testWidgets('neither is listed while there is nothing to move', (
    tester,
  ) async {
    await open(
      tester,
      before: (container) {
        container
            .read(terminalSessionsControllerProvider.notifier)
            .openTab(TerminalProfile.powerShell);
      },
    );

    await type(tester, 'move');

    expect(find.text('Move a tab into the empty split…'), findsNothing);
    expect(find.text('Move this pane to a new tab'), findsNothing);
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

  group('a scheduled resume', () {
    void select(ProviderContainer container) =>
        container.read(selectedSessionIdProvider.notifier).select('s1');

    testWidgets('the session on screen can be armed from the palette', (
      tester,
    ) async {
      await open(tester, before: select);
      await type(tester, 'usage resets');
      expect(find.text('Resume when usage resets…'), findsOneWidget);
      expect(find.text('Cancel scheduled resume'), findsNothing);
      expect(find.text('Scheduled resumes'), findsNothing);

      await tester.tap(find.text('Resume when usage resets…'));
      await tester.pumpAndSettle();
      expect(find.byType(ResumeOnResetDialog), findsOneWidget);
    });

    testWidgets('with nothing on screen there is nothing to arm', (
      tester,
    ) async {
      await open(tester);
      await type(tester, 'usage resets');
      expect(find.text('Resume when usage resets…'), findsNothing);
    });

    testWidgets('one that is waiting can be changed, cancelled, and found in '
        'the list of them all', (tester) async {
      final container = await open(
        tester,
        before: (container) {
          select(container);
          db.server.sessionRows.updatePermissionMode(
            's1',
            'mode=bypassPermissions',
          );
          container
              .read(scheduledResumeControllerProvider)
              .schedule(
                ResumeRequest(
                  sessionId: 's1',
                  fireAt: DateTime.now().toUtc().add(const Duration(hours: 2)),
                ),
              );
        },
      );
      await type(tester, 'scheduled resume');
      expect(find.text('Change scheduled resume…'), findsOneWidget);
      // The command, and Settings' own section of the same name under it.
      expect(find.text('Scheduled resumes'), findsWidgets);
      expect(find.text('1 waiting'), findsOneWidget);

      await tester.tap(find.text('Cancel scheduled resume'));
      await tester.pumpAndSettle();
      expect(container.read(resumesDataProvider).liveFor('s1'), isNull);
    });
  });
}

/// Records what quick open asked to open, standing in for the real actions so
/// the test never starts a process.
/// Records an explicit resume instead of resuming.
class _SpyResumer extends OverviewResumer {
  _SpyResumer(super.ref);

  final resumed = <String>[];

  @override
  Future<ExplorerResult> resume(String sessionId, {String? message}) async {
    resumed.add(sessionId);
    return const ExplorerResult(ExplorerOutcome.resumed);
  }
}

class _SpyActions extends ExplorerActions {
  _SpyActions(super.ref);

  final List<String> opened = [];

  @override
  Future<ExplorerResult> openNative(String sessionId) async {
    opened.add(sessionId);
    return const ExplorerResult(ExplorerOutcome.selected);
  }
}
