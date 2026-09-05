import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/app/theme/app_theme.dart';
import 'package:karmashala/src/app/theme/design_tokens.dart';
import 'package:karmashala/src/app/widgets/desktop_menu.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/domain/pane_layout.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:karmashala/src/features/terminal/presentation/pane_group_strip.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart';

import '../features/terminal/fake_instance.dart';
import 'package:karmashala/src/app/shell/shell_shortcuts.dart';

/// The terminal's three right-click menus draw the *house* menu row.
///
/// They were raw `PopupMenuItem`s with a bare `Text` child, which Material
/// renders at 48px with no icon — visibly a different kind of menu from the one
/// the Explorer and the Files panel open two panes away. These pin the fix:
/// every row is a [DesktopMenuItem], so a change back to a plain item is a test
/// failure rather than something only a screenshot would catch.
void main() {
  // Pinned to the platform whose modifier these labels name. The menu draws
  // whatever the chord table says, and on macOS copy is `⌘C` — a Mac terminal
  // has no reason for the shift, because Ctrl+C is not copy there. Which
  // modifier each chord carries is pinned in
  // `test/app/shell/shell_shortcuts_platform_test.dart`; what this case is
  // about is that the menu shows the chord it really binds.
  setUp(() => commandKeyIsMeta = false);

  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase.memory();
    container = fakeTerminalContainer(database: db);
  });

  tearDown(() {
    container.dispose();
    db.close();
  });

  TerminalSessionsController terminals() =>
      container.read(terminalSessionsControllerProvider.notifier);

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
  }

  /// Every row of the open menu, asserted to be a house row of the house height.
  void expectHouseRows(WidgetTester tester, {required int rows}) {
    final items = find.byType(DesktopMenuItem<String>);
    expect(items, findsNWidgets(rows));
    expect(
      find.byType(PopupMenuItem<String>),
      findsNothing,
      reason: 'a bare PopupMenuItem is the 48px Material row this replaced',
    );
    for (var i = 0; i < rows; i++) {
      expect(tester.getSize(items.at(i)).height, Chrome.menuRow);
    }
  }

  testWidgets('the tab menu draws house rows, with End session in the error '
      'colour', (tester) async {
    await pump(tester);

    await tester.tap(find.byType(TerminalTabChip), buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    // Close tab, the four bulk closes, End session.
    expectHouseRows(tester, rows: 6);
    expect(find.byType(DesktopMenuDivider), findsOneWidget);
    final label = tester.widget<Text>(find.text('End session'));
    expect(
      label.style?.color,
      AppTheme.light().colorScheme.error,
      reason: 'ending a session is the destructive verb of this menu',
    );
  });

  testWidgets('the pane chip menu draws house rows', (tester) async {
    await pump(tester);
    // The chip only exists where a region stacks panes now — a split whose
    // regions hold one pane each draws no header at all.
    final host = terminals().state.activeTab!;
    final guest = terminals().openTab(TerminalProfile.commandPrompt);
    terminals().moveTabIntoSlot(guest, host.layout.panes.single);
    await tester.pumpAndSettle();
    expect(find.byType(PaneTabChip), findsNWidgets(2));

    await tester.tap(find.byType(PaneTabChip).first, buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expectHouseRows(tester, rows: 3);
    expect(find.byType(DesktopMenuDivider), findsOneWidget);
  });

  testWidgets('and a split pane reaches the same verbs from its own body', (
    tester,
  ) async {
    // The route to a pane's verbs in an ordinary split: right-click the
    // terminal. Copy, Paste, Find…, the two pane splits, then the pane pair,
    // then End session.
    await pump(tester);
    terminals().openInSlot(
      terminals().splitPane(SplitAxis.horizontal)!,
      TerminalProfile.commandPrompt,
    );
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(200, 400), buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expectHouseRows(tester, rows: 8);
    expect(find.byType(DesktopMenuDivider), findsNWidgets(3));
    expect(find.text('Move pane to a new tab'), findsOneWidget);
    expect(find.text('Close pane'), findsOneWidget);
  });

  testWidgets('the terminal body menu draws house rows, with the chords it '
      'really binds', (tester) async {
    await pump(tester);

    await tester.tapAt(const Offset(400, 400), buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    // Copy, Paste, Find…, the two pane splits, End session — the split-only
    // pair is absent because there is no split to collapse.
    expectHouseRows(tester, rows: 6);
    expect(find.text('Ctrl+Shift+C'), findsOneWidget);
    expect(find.text('Ctrl+Shift+V'), findsOneWidget);
    expect(
      find.text(shellChordLabel<FindInScrollbackIntent>()!),
      findsOneWidget,
    );
  });
}
