import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/window_matrix.dart';
import '../../support/test_machine.dart';

/// VS Code's bulk tab closes, and the one question they ask that a single close
/// does not.
///
/// A single close is a *view* action: the tab goes, the session keeps running,
/// and that is the behaviour the X has always had. A bulk close is the user
/// clearing the deck — and quietly parking a dozen live agents in the
/// background list is the outcome nobody wants — so a set with anything live in
/// it asks first, with *end* as the default answer.
void main() {
  late TestMachine db;
  late ProviderContainer container;

  setUp(() {
    db = TestMachine();
    container = fakeTerminalContainer(machine: db);
  });

  tearDown(() {
    container.dispose();
  });

  TerminalSessionsController terminals() =>
      container.read(terminalSessionsControllerProvider.notifier);

  List<String> openTabs(int count) => [
    for (var i = 0; i < count; i++)
      terminals().openTab(
        TerminalProfile.powerShell,
        workingDirectory:
            r'C:\src\p'
            '$i',
      ),
  ];

  List<String> openTabIds() => [
    for (final tab in container.read(terminalSessionsControllerProvider).tabs)
      tab.id,
  ];

  /// Gives every pane the history [shouldDetachOnClose] needs before it will
  /// keep a shell alive. Without it a fake pane's buffer is empty, the policy
  /// reads it as a shell nobody would miss, and *every* close releases.
  void giveEveryPaneHistory() {
    for (final tab in container.read(terminalSessionsControllerProvider).tabs) {
      for (final paneId in tab.layout.panes) {
        terminals().instanceFor(paneId)!.terminal.write('a long build\r\n' * 8);
      }
    }
  }

  /// Ends every pane's process, so the set a bulk close would take has nothing
  /// live in it and there is no question to ask.
  ///
  /// **Non-zero on purpose.** The confirmation is about panes that are still
  /// *running*, so any exit satisfies what this fixture is for — but a clean
  /// one now means "the user typed `exit`" and `shouldCollapseOnExit` closes
  /// the tab for it. Exiting every pane with 0 would leave no tabs for the
  /// bulk close to act on, which is a different test than this one.
  void exitEveryPane() {
    for (final tab in container.read(terminalSessionsControllerProvider).tabs) {
      for (final paneId in tab.layout.panes) {
        (terminals().instanceFor(paneId)! as FakeTerminalInstance).exitWith(1);
      }
    }
  }

  Widget app() => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const Scaffold(body: WorkbenchView()),
    ),
  );

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
  }

  Future<void> openMenu(WidgetTester tester, int index) async {
    await tester.tap(
      find.byType(TerminalTabChip).at(index),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
  }

  Future<void> dismiss(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  }

  bool rowEnabled(WidgetTester tester, TabCloseScope scope) => tester
      .widget<DesktopMenuItem<String>>(
        find.ancestor(
          of: find.text(scope.label),
          matching: find.byType(DesktopMenuItem<String>),
        ),
      )
      .enabled;

  Future<void> pick(WidgetTester tester, TabCloseScope scope) async {
    await tester.tap(find.text(scope.label));
    await tester.pumpAndSettle();
  }

  group('what each row offers', () {
    testWidgets('the first tab has nothing to its left', (tester) async {
      openTabs(3);
      await pump(tester);

      await openMenu(tester, 0);

      expect(rowEnabled(tester, TabCloseScope.others), isTrue);
      expect(rowEnabled(tester, TabCloseScope.toTheRight), isTrue);
      expect(rowEnabled(tester, TabCloseScope.toTheLeft), isFalse);
      expect(rowEnabled(tester, TabCloseScope.all), isTrue);
      await dismiss(tester);
    });

    testWidgets('a middle tab has both directions', (tester) async {
      openTabs(3);
      await pump(tester);

      await openMenu(tester, 1);

      expect(rowEnabled(tester, TabCloseScope.toTheRight), isTrue);
      expect(rowEnabled(tester, TabCloseScope.toTheLeft), isTrue);
      await dismiss(tester);
    });

    testWidgets('the last tab has nothing to its right', (tester) async {
      openTabs(3);
      await pump(tester);

      await openMenu(tester, 2);

      expect(rowEnabled(tester, TabCloseScope.toTheRight), isFalse);
      expect(rowEnabled(tester, TabCloseScope.toTheLeft), isTrue);
      await dismiss(tester);
    });

    testWidgets('the only tab offers no bulk close at all', (tester) async {
      // Every one of them would close nothing, or would do exactly what "Close
      // tab" one row above already does.
      openTabs(1);
      await pump(tester);

      await openMenu(tester, 0);

      for (final scope in TabCloseScope.values) {
        expect(rowEnabled(tester, scope), isFalse, reason: scope.label);
      }
      expect(find.text('Close tab'), findsOneWidget);
      await dismiss(tester);
    });
  });

  group('the set each row closes', () {
    // Nothing is running in any of these, so the confirmation has no question
    // to put and the close happens on the click.
    testWidgets('others leaves the tab it was opened from', (tester) async {
      final ids = openTabs(4);
      await pump(tester);
      exitEveryPane();

      await openMenu(tester, 1);
      await pick(tester, TabCloseScope.others);

      expect(openTabIds(), [ids[1]]);
    });

    testWidgets('to the right leaves everything up to it', (tester) async {
      final ids = openTabs(4);
      await pump(tester);
      exitEveryPane();

      await openMenu(tester, 1);
      await pick(tester, TabCloseScope.toTheRight);

      expect(openTabIds(), [ids[0], ids[1]]);
    });

    testWidgets('to the left leaves everything from it on', (tester) async {
      final ids = openTabs(4);
      await pump(tester);
      exitEveryPane();

      await openMenu(tester, 2);
      await pick(tester, TabCloseScope.toTheLeft);

      expect(openTabIds(), [ids[2], ids[3]]);
    });

    testWidgets('all leaves the empty workbench', (tester) async {
      openTabs(4);
      await pump(tester);
      exitEveryPane();

      await openMenu(tester, 2);
      await pick(tester, TabCloseScope.all);

      expect(openTabIds(), isEmpty);
      expect(find.text('No terminal open'), findsOneWidget);
    });

    testWidgets('the tab it was opened from is the one left in front', (
      tester,
    ) async {
      final ids = openTabs(4);
      terminals().activateTab(ids.first);
      await pump(tester);
      exitEveryPane();
      // The bulk close takes the active tab with it, so something has to take
      // its place — and it must be the tab the user pointed at, not whatever
      // happens to be last in the list.
      await openMenu(tester, 1);
      await pick(tester, TabCloseScope.toTheLeft);

      expect(openTabIds(), [ids[1], ids[2], ids[3]]);
      expect(
        container.read(terminalSessionsControllerProvider).activeTabId,
        ids[1],
      );
    });
  });

  group('the confirmation', () {
    final dialog = find.text('Close, keep running');

    testWidgets('a set with nothing running in it is never questioned', (
      tester,
    ) async {
      openTabs(3);
      await pump(tester);
      exitEveryPane();

      await openMenu(tester, 0);
      await pick(tester, TabCloseScope.others);

      expect(dialog, findsNothing);
      expect(openTabIds(), hasLength(1));
    });

    testWidgets('a set with a live session in it asks before anything moves', (
      tester,
    ) async {
      openTabs(3);
      await pump(tester);

      await openMenu(tester, 0);
      await pick(tester, TabCloseScope.others);

      expect(dialog, findsOneWidget);
      expect(find.text('Close 2 tabs?'), findsOneWidget);
      expect(find.text('End 2 sessions'), findsOneWidget);
      expect(openTabIds(), hasLength(3), reason: 'nothing has happened yet');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    });

    testWidgets('Cancel changes nothing', (tester) async {
      final ids = openTabs(3);
      await pump(tester);

      await openMenu(tester, 0);
      await pick(tester, TabCloseScope.all);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(openTabIds(), ids);
      expect(
        container.read(terminalSessionsControllerProvider).detached,
        isEmpty,
      );
    });

    testWidgets('End ends them, leaving nothing in the background', (
      tester,
    ) async {
      openTabs(3);
      await pump(tester);
      giveEveryPaneHistory();

      await openMenu(tester, 0);
      await pick(tester, TabCloseScope.others);
      await tester.tap(find.text('End 2 sessions'));
      await tester.pumpAndSettle();

      expect(openTabIds(), hasLength(1));
      expect(
        container.read(terminalSessionsControllerProvider).detached,
        isEmpty,
        reason: 'ending is ending — the whole point of the primary action',
      );
    });

    testWidgets('Close, keep running detaches them instead', (tester) async {
      openTabs(3);
      await pump(tester);
      giveEveryPaneHistory();

      await openMenu(tester, 0);
      await pick(tester, TabCloseScope.others);
      await tester.tap(find.text('Close, keep running'));
      await tester.pumpAndSettle();

      expect(openTabIds(), hasLength(1));
      expect(
        container.read(terminalSessionsControllerProvider).detached,
        hasLength(2),
        reason: 'the old behaviour is still one click away',
      );
    });

    testWidgets('closing one tab still never asks', (tester) async {
      // The rule the bulk closes are the exception to: the X, and the single
      // row above them, detach without a word.
      openTabs(3);
      await pump(tester);
      giveEveryPaneHistory();

      await openMenu(tester, 0);
      await tester.tap(find.text('Close tab'));
      await tester.pumpAndSettle();

      expect(dialog, findsNothing);
      expect(openTabIds(), hasLength(2));
      expect(
        container.read(terminalSessionsControllerProvider).detached,
        hasLength(1),
      );
    });
  });

  testWidgets('the menu and its confirmation survive the window matrix', (
    tester,
  ) async {
    openTabs(4);
    await expectSurvivesWindowMatrix(
      tester,
      build: app,
      warmUp: (tester) async {
        await tester.tap(
          find.byType(TerminalTabChip).at(1),
          buttons: kSecondaryButton,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(TabCloseScope.others.label));
        await tester.pumpAndSettle();
      },
      because:
          'the tab menu and the question it asks are reached at every size',
    );
  });

  /// **Middle click is the reversible close, deliberately.**
  ///
  /// It is a wheel press — mushy on most mice and easy to fire while
  /// scrolling — so it gets the action whose cost can be undone, not
  /// `closeTab(detach: false)`. This file's own opening line is the rule:
  /// a single close is a *view* action, the tab goes and the session keeps
  /// running. Ending one stays behind a menu item with a word on it.
  ///
  /// It lives on [WorkbenchTabChip], which both strips share, so a window
  /// split into groups behaves the same in every one of them — a gesture that
  /// worked in one strip and not its neighbour would be worse than none.
  testWidgets('a middle click closes the tab and parks its session', (
    tester,
  ) async {
    await pump(tester);
    openTabs(2);
    giveEveryPaneHistory();
    await tester.pumpAndSettle();
    // Relative to what is open, because `pump` opens a tab of its own.
    final before = openTabIds();
    expect(before, hasLength(3));

    await tester.tap(
      find.byType(WorkbenchTabChip).first,
      buttons: kTertiaryButton,
    );
    await tester.pumpAndSettle();

    expect(
      openTabIds(),
      before.sublist(1),
      reason: 'the tab the click landed on is gone, and only that one',
    );
    expect(
      container.read(terminalSessionsControllerProvider).detached,
      hasLength(1),
      reason: 'parked, not killed — it comes back through the status bar count',
    );
  });
}
