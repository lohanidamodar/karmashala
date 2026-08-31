import 'package:chitragupta/src/app/shell/workbench.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:chitragupta/src/features/terminal/domain/pane_layout.dart';
import 'package:chitragupta/src/features/terminal/domain/pane_liveness.dart';
import 'package:chitragupta/src/features/terminal/domain/terminal_profile.dart';
import 'package:chitragupta/src/features/terminal/presentation/session_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';
import 'terminal_panel_test.dart' show panelContainer, pumpPanel;

/// The one pane of [tabId].
String paneOf(ProviderContainer container, String tabId) => container
    .read(terminalSessionsControllerProvider)
    .tabs
    .firstWhere((t) => t.id == tabId)
    .layout
    .panes
    .single;

void main() {
  group('PaneStatusBar', () {
    Future<void> pump(WidgetTester tester, PaneLiveness liveness) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PaneStatusBar(
              liveness: liveness,
              workingDirectory: r'C:\ws',
              onStart: () {},
            ),
          ),
        ),
      );
    }

    testWidgets('a restored pane says so in words, not just colour', (
      tester,
    ) async {
      await pump(tester, PaneLiveness.restored);

      expect(
        find.textContaining('Restored history — nothing is running here'),
        findsOneWidget,
      );
      expect(find.textContaining(r'C:\ws'), findsOneWidget);
      expect(find.text('Start'), findsOneWidget);
    });

    testWidgets('an ended pane offers a restart, not a start', (tester) async {
      await pump(tester, PaneLiveness.exited);

      expect(find.textContaining('Session ended'), findsOneWidget);
      expect(find.text('Restart'), findsOneWidget);
    });
  });

  group('describeAge', () {
    final now = DateTime.utc(2026, 8, 30, 12);
    test('rounds to the roughest useful unit', () {
      expect(
        describeAge(now.subtract(const Duration(seconds: 20)), now: now),
        'just now',
      );
      expect(
        describeAge(now.subtract(const Duration(minutes: 5)), now: now),
        '5m ago',
      );
      expect(
        describeAge(now.subtract(const Duration(hours: 3)), now: now),
        '3h ago',
      );
      expect(
        describeAge(now.subtract(const Duration(days: 2)), now: now),
        '2d ago',
      );
    });
  });

  group('the panel', () {
    testWidgets('a restored pane is not presented as a live terminal', (
      tester,
    ) async {
      final container = panelContainer();
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      controller.openTab(TerminalProfile.powerShell);
      final pane = container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .single;

      await pumpPanel(tester, container);
      expect(find.byType(PaneStatusBar), findsNothing);

      (controller.instanceFor(pane)! as FakeTerminalInstance)
              .livenessNotifier
              .value =
          PaneLiveness.exited;
      await tester.pump();

      expect(find.byType(PaneStatusBar), findsOneWidget);
      expect(find.text('Restart'), findsOneWidget);
    });

    testWidgets('the tab bar shows nothing until a session is detached', (
      tester,
    ) async {
      final container = panelContainer();
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final tabId = controller.openTab(TerminalProfile.powerShell);
      giveShellHistory(controller.instanceFor(paneOf(container, tabId))!);
      controller.openTab(TerminalProfile.commandPrompt);

      await pumpPanel(tester, container);
      expect(find.byType(Badge), findsNothing);

      controller.closeTab(tabId);
      await tester.pump();

      expect(find.byType(Badge), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('closing the last tab keeps its session reachable', (
      tester,
    ) async {
      final container = panelContainer();
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final tabId = controller.openTab(TerminalProfile.powerShell);
      final pane = container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .single;
      giveShellHistory(controller.instanceFor(pane)!);

      await pumpPanel(tester, container);
      await tester.tap(find.byTooltip('Close tab (the session keeps running)'));
      await tester.pump();

      final state = container.read(terminalSessionsControllerProvider);
      expect(state.tabs.map((t) => t.id), isNot(contains(tabId)));
      expect(state.detached.map((s) => s.paneId), [pane]);
      expect(controller.instanceFor(pane), isNotNull);
    });

    testWidgets('a background session can be attached from the dialog', (
      tester,
    ) async {
      final container = panelContainer();
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final first = controller.openTab(TerminalProfile.powerShell);
      controller.openTab(TerminalProfile.commandPrompt);
      final pane = container
          .read(terminalSessionsControllerProvider)
          .tabs
          .firstWhere((t) => t.id == first)
          .layout
          .panes
          .single;
      giveShellHistory(controller.instanceFor(pane)!);
      controller.closeTab(first);

      await pumpPanel(tester, container);
      await tester.tap(find.byType(Badge));
      await tester.pumpAndSettle();

      expect(find.text('Background sessions'), findsOneWidget);
      expect(find.textContaining('Running · detached'), findsOneWidget);

      await tester.tap(find.text('Attach'));
      await tester.pumpAndSettle();

      final state = container.read(terminalSessionsControllerProvider);
      expect(state.detached, isEmpty);
      expect(
        state.tabs.map((t) => t.layout.panes).expand((p) => p),
        contains(pane),
      );
    });

    testWidgets('End all clears every background session', (tester) async {
      final container = panelContainer();
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final first = controller.openTab(TerminalProfile.powerShell);
      giveShellHistory(controller.instanceFor(paneOf(container, first))!);
      controller.openTab(TerminalProfile.commandPrompt);
      controller.closeTab(first);

      await pumpPanel(tester, container);
      await tester.tap(find.byType(Badge));
      await tester.pumpAndSettle();
      await tester.tap(find.text('End all'));
      await tester.pumpAndSettle();

      expect(container.read(terminalSessionsControllerProvider).detached, []);
    });

    testWidgets('unmounting the whole panel leaves every session running', (
      tester,
    ) async {
      final container = panelContainer();
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      controller.openTab(TerminalProfile.powerShell);
      final pane = container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .single;

      await pumpPanel(tester, container);
      // Hiding the terminal, and closing the window to the tray, both come down
      // to the view going away while the app keeps running. The instances
      // belong to the controller, not the widget, so neither touches them.
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
        ),
      );
      await tester.pump();

      expect(find.byType(WorkbenchView), findsNothing);
      final instance = controller.instanceFor(pane);
      expect(instance, isNotNull);
      expect((instance! as FakeTerminalInstance).disposed, isFalse);
      expect(
        container.read(terminalSessionsControllerProvider).livenessOf(pane),
        PaneLiveness.live,
      );
    });

    testWidgets('splitting keeps each pane independently marked', (
      tester,
    ) async {
      final container = panelContainer();
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      controller.openTab(TerminalProfile.powerShell);
      final second = controller.splitPane(
        SplitAxis.horizontal,
        TerminalProfile.commandPrompt,
      )!;

      await pumpPanel(tester, container);
      (controller.instanceFor(second)! as FakeTerminalInstance)
              .livenessNotifier
              .value =
          PaneLiveness.exited;
      await tester.pump();

      expect(
        find.byType(PaneStatusBar),
        findsOneWidget,
        reason: 'only the dead pane is marked, not its live neighbour',
      );
    });
  });
}
