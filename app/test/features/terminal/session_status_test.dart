import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala/src/features/terminal/presentation/session_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';
import 'terminal_panel_test.dart'
    show panelContainer, pumpPanel, pumpWindowChrome;

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
    Future<void> pump(
      WidgetTester tester,
      PaneLiveness liveness, {
      bool resumes = false,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PaneStatusBar(
              liveness: liveness,
              resumes: resumes,
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

    testWidgets('a restored pane that resumes says so, and says nothing '
        'different about the history', (tester) async {
      await pump(tester, PaneLiveness.restored, resumes: true);

      // The sentence is the same one — the pane really is restored history
      // either way. Only the verb changes, because only the verb was wrong.
      expect(
        find.textContaining('Restored history — nothing is running here'),
        findsOneWidget,
      );
      expect(find.text('Resume'), findsOneWidget);
      expect(find.text('Start'), findsNothing);
    });

    testWidgets('a pane that could not start offers Retry, and its Details '
        'show the whole account the terminal left out', (tester) async {
      const long =
          'dev@198.51.100.7:22 is linux-x64, and the Karmashala server '
          'has no host bundle for it (it looked in /Users/me/.karmashala/'
          'host-bundles). Nothing was put on the machine.';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => PaneStatusBar(
                liveness: PaneLiveness.exited,
                didNotStart: true,
                onDetails: () => PaneFailureDetailsDialog.show(context, long),
                onStart: () {},
              ),
            ),
          ),
        ),
      );

      expect(find.textContaining("Couldn't start"), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Restart'), findsNothing);
      expect(find.textContaining('198.51.100.7'), findsNothing);

      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(find.text(long), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text(long), findsNothing);
    });

    testWidgets('with nothing more to say there is no Details', (tester) async {
      await pump(tester, PaneLiveness.exited);
      expect(find.text('Details'), findsNothing);
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

    /// Which of the two verbs the button runs, from the panel rather than from
    /// the rule — because the rule being right is no use if the bar asks it a
    /// different question than the button does.
    testWidgets('a restored agent pane offers a resume, and pressing it '
        'starts no process here', (tester) async {
      final container = panelContainer();
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final opened = controller.openAgentTab(
        const AgentPaneLaunch(
          agentId: 'claudeCode',
          executable: 'claude',
          // Recorded exactly as a fresh conversation records itself: the
          // opening prompt is *in* the durable arguments.
          arguments: ['--session-id', 'sess-1', 'summarise yesterday'],
          workingDirectory: r'C:\ws',
          sessionId: 'sess-1',
          title: 'Earlier work',
        ),
      );
      final instance =
          controller.instanceFor(opened.paneId)! as FakeTerminalInstance;
      instance.livenessNotifier.value = PaneLiveness.restored;

      await pumpPanel(tester, container);
      expect(find.text('Resume'), findsOneWidget);

      await tester.tap(find.text('Resume'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // There is no session row in this container, so the resume refuses — and
      // what it must not do on the way out is fall back to re-running the
      // recorded line, which is what `startPane` would have done.
      expect(
        controller.instanceFor(opened.paneId),
        same(instance),
        reason: 'the pane was not released and rebuilt around a new process',
      );
      expect(
        container
            .read(terminalSessionsControllerProvider)
            .livenessOf(opened.paneId),
        PaneLiveness.restored,
      );
      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgets('a restored shell pane still starts what it recorded', (
      tester,
    ) async {
      final container = panelContainer();
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final tabId = controller.openTab(TerminalProfile.powerShell);
      final pane = paneOf(container, tabId);
      final instance = controller.instanceFor(pane)! as FakeTerminalInstance;
      instance.livenessNotifier.value = PaneLiveness.restored;

      await pumpPanel(tester, container);
      // Re-running `pwsh` in the directory it was in is not an approximation
      // of what the user wants; it is what they want.
      expect(find.text('Start'), findsOneWidget);
      expect(find.text('Resume'), findsNothing);

      await tester.tap(find.text('Start'));
      await tester.pump();

      expect(controller.instanceFor(pane), isNot(same(instance)));
      expect(
        container.read(terminalSessionsControllerProvider).livenessOf(pane),
        PaneLiveness.live,
      );
    });

    /// The bulk control, and the two things it must not be: always there, or a
    /// button that starts four agents without saying which four.
    testWidgets('the title bar offers a resume only once a restart has left '
        'something dormant', (tester) async {
      final container = panelContainer();
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      controller.openTab(TerminalProfile.powerShell);

      await pumpWindowChrome(tester, container);
      expect(find.byTooltip(_restoredTooltip(1)), findsNothing);
      expect(find.byTooltip(_restoredTooltip(2)), findsNothing);

      final panes = [
        for (var i = 0; i < 2; i++)
          controller
              .openAgentTab(
                AgentPaneLaunch(
                  agentId: 'claudeCode',
                  executable: 'claude',
                  workingDirectory: r'C:\ws',
                  sessionId: 'sess-$i',
                  title: 'Earlier work $i',
                ),
              )
              .paneId,
      ];
      // A shell left dormant beside them, which is not what this counts.
      controller.openTab(TerminalProfile.commandPrompt);
      final shell = container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .single;
      for (final paneId in [...panes, shell]) {
        (controller.instanceFor(paneId)! as FakeTerminalInstance)
                .livenessNotifier
                .value =
            PaneLiveness.restored;
      }
      await tester.pump();

      expect(find.byTooltip(_restoredTooltip(2)), findsOneWidget);

      await tester.tap(find.byTooltip(_restoredTooltip(2)));
      await tester.pumpAndSettle();

      // Scoped to the dialog: these sessions are named on their tab chips too,
      // and finding one there would prove nothing about the list.
      Finder inDialog(Finder finder) => find.descendant(
        of: find.byType(RestoredSessionsDialog),
        matching: finder,
      );
      expect(find.text('Restored sessions'), findsOneWidget);
      expect(inDialog(find.text('Earlier work 0')), findsOneWidget);
      expect(inDialog(find.text('Earlier work 1')), findsOneWidget);
      expect(
        find.text('Resume all (2)'),
        findsOneWidget,
        reason: 'the bulk verb lives in the dialog, beside the list it acts on',
      );
      // The shell is dormant too, and is not this dialog's business: its own
      // Start button already does the right thing.
      expect(inDialog(find.textContaining('PowerShell')), findsNothing);
      expect(inDialog(find.text('Resume')), findsNWidgets(2));
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
      final second = controller.splitPaneWith(
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

/// The toolbar badge's tooltip, spelled the way the strip spells it.
String _restoredTooltip(int count) =>
    '$count restored session${count == 1 ? '' : 's'} — nothing running in '
    '${count == 1 ? 'it' : 'them'}';
