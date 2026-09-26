import 'package:karmashala/src/app/shell/app_shell.dart';
import 'package:karmashala/src/app/shell/tab_picker.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_handoff_service.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/window_matrix.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';
import 'package:agent_cli/process.dart';

void main() {
  testWidgets('a tab\'s close button sits at its edge, not beside the text', (
    tester,
  ) async {
    // Reported: "the tabs close button is aligned to text not to the tab pad
    // itself". The strip lays tabs out at a uniform extent, so a short title
    // left the row hugging its content and the X floating in the middle of the
    // tab with empty space after it.
    const key = Key('slot');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              key: key,
              width: 220,
              child: TerminalTabChip(
                title: 'zsh',
                liveness: PaneLiveness.live,
                selected: true,
                index: 0,
                tabCount: 1,
                onTap: () {},
                onClose: () {},
                onEnd: () {},
                onBulkClose: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    final slot = tester.getRect(find.byKey(key));
    final button = tester.getRect(find.byType(IconButton));
    expect(
      slot.right - button.right,
      lessThan(8),
      reason: 'the X belongs to the tab, and the tab ends where the slot does',
    );
  });

  group('tabStripMetrics', () {
    test('one tab draws at its natural width, not the whole strip', () {
      final metrics = tabStripMetrics(1200, 1);

      expect(metrics.extent, kMaxTabWidth);
      expect(metrics.overflowing, isFalse);
    });

    test('tabs share the room evenly once there is not enough for the cap', () {
      // Six into 900 is 150: under the cap, over the floor, so nothing is
      // clipped and nothing scrolls.
      final metrics = tabStripMetrics(900, 6);

      expect(metrics.extent, 150);
      expect(metrics.overflowing, isFalse);
    });

    test(
      'they stop shrinking at the floor, and that is where overflow starts',
      () {
        // 900 / 10 is 90, under the floor: the tenth tab is the one that does
        // not fit.
        expect(tabStripMetrics(900, 8).overflowing, isFalse);
        final metrics = tabStripMetrics(900, 10);

        expect(metrics.extent, kMinTabWidth);
        expect(metrics.overflowing, isTrue);
      },
    );

    test('a hundred tabs overflow every window the app supports', () {
      // The 720px minimum window and a 4K one alike: this is why the picker
      // exists and better scrolling does not answer it.
      expect(tabStripMetrics(720, 100).overflowing, isTrue);
      expect(tabStripMetrics(3840, 100).overflowing, isTrue);
    });

    test('an empty strip asks for nothing', () {
      expect(tabStripMetrics(900, 0).overflowing, isFalse);
    });
  });

  group('the strip', () {
    late TestMachine db;
    late ProviderContainer container;

    setUp(() async {
      db = TestMachine();
      final server = FakeDataServer()..runsOn(db);
      server.environmentRows.upsert(
        localHostEnvironment(FixedClock(testTime).nowUtc()),
      );
      server.projectRows.insert(project());
      server.repositoryRows.insert(repository());
      server.installationRows.insert(agentInstallation());
      final data = await server.override();
      container = ProviderContainer(
        overrides: [
          data,
          ...fakeTerminalOverrides(machine: db),
          // A selected session brings the chat surface with it, and every one
          // of these otherwise polls on a real timer or reaches the host. The
          // strip does not care what they say — only that a session has two
          // renderings and therefore a tab of its own.
          sessionTranscriptProvider.overrideWith(
            (ref, id) => Stream.value(const []),
          ),
          availableSystemTerminalsProvider.overrideWith(
            (ref) async => const <SystemTerminal>[],
          ),
          hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
          sessionDeliveryProvider.overrideWith(
            (ref, _) async => SessionDelivery.unknown,
          ),
          sessionContinuationProvider.overrideWith(
            (ref, _) => SessionContinuation(
              targets: const [],
              plan: SessionForkPlan.decide(
                descriptor: null,
                agentName: 'Test CLI',
              ),
            ),
          ),
          agentSessionStatusProvider.overrideWith(
            (ref, id) => Stream.value(
              AgentStatusReport(
                agentId: AgentIds.claudeCode,
                sessionId: id,
                status: AgentActivityStatus.idle,
                observedAt: testTime,
                source: AgentStatusSource.terminalGrid,
                evidence: const [],
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
    });

    TerminalSessionsController terminals() =>
        container.read(terminalSessionsControllerProvider.notifier);

    /// Opens [count] tabs, each in a directory of its own — which is what a
    /// window of identically-titled `PowerShell` tabs has to be told apart by.
    ///
    /// Leaves the *first* tab active. Opening a tab activates it, so without
    /// this every test would start with the strip already scrolled to the far
    /// end and the two chevrons the other way round.
    List<String> openTabs(int count) {
      final ids = [
        for (var i = 0; i < count; i++)
          terminals().openTab(
            TerminalProfile.powerShell,
            workingDirectory:
                r'C:\src\p'
                '$i',
          ),
      ];
      terminals().activateTab(ids.first);
      return ids;
    }

    /// [chrome] adds the window's title bar over the workbench, for the cases
    /// about controls that live there — the new-terminal pair moved up when
    /// every workspace group got a strip of its own.
    Future<void> pump(
      WidgetTester tester, {
      Size size = const Size(1200, 800),
      bool chrome = false,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              appBar: chrome ? const ShellTitleBar() : null,
              body: const WorkbenchView(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// The strip's own scroll view — the only horizontal one in the workbench.
    ListView strip(WidgetTester tester) => tester.widget<ListView>(
      find.byWidgetPredicate(
        (widget) =>
            widget is ListView && widget.scrollDirection == Axis.horizontal,
      ),
    );

    Finder overflowButton(int count) =>
        find.byTooltip('All $count tabs — filter and switch');

    /// The chevron itself: `byTooltip` lands on the tooltip the button builds
    /// around itself, not on the button.
    IconButton chevron(WidgetTester tester, String tip) => tester.widget(
      find.ancestor(of: find.byTooltip(tip), matching: find.byType(IconButton)),
    );

    testWidgets('the + opens the default terminal, the caret offers the rest', (
      tester,
    ) async {
      // Reported: "plus button with new terminal tab should open new default
      // terminal, there should be another button to open different terminal
      // like vs code provides". The + used to only ever open a menu.
      openTabs(1);
      await pump(tester, chrome: true);

      await tester.tap(find.byTooltip(RegExp(r'^New terminal \(')));
      await tester.pumpAndSettle();
      expect(
        find.byType(PopupMenuItem<TerminalProfile>),
        findsNothing,
        reason: 'the common case must not cost a choice',
      );
      expect(
        container.read(terminalSessionsControllerProvider).tabs,
        hasLength(2),
      );

      await tester.tap(find.byTooltip('New terminal with a different profile'));
      await tester.pumpAndSettle();
      expect(find.byType(PopupMenuItem<TerminalProfile>), findsWidgets);

      // Dismissed before the tree goes: a menu route torn down with a focus
      // change still in flight takes the focus manager with it, and the next
      // test in the file is the one that reports it.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      // And the tree torn down while the binding is still alive: this is the
      // only test here that opens a tab — and so focuses a new pane — with the
      // widgets already mounted, and that focus change has to land somewhere.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets('a strip that fits offers nothing to fix it', (tester) async {
      openTabs(4);
      await pump(tester);

      expect(find.byTooltip('Earlier tabs'), findsNothing);
      expect(find.byTooltip('Later tabs'), findsNothing);
      expect(overflowButton(4), findsNothing);
      // And it does not scroll, because there is nothing off the end.
      expect(strip(tester).controller!.position.maxScrollExtent, 0);
    });

    testWidgets('overflow brings out the chevrons and the picker button', (
      tester,
    ) async {
      openTabs(30);
      await pump(tester);

      expect(overflowButton(30), findsOneWidget);
      expect(find.byTooltip('Later tabs'), findsOneWidget);
      // At the left end there is nothing earlier to reach, so that chevron is
      // there but does nothing — a live button that scrolls nowhere is worse.
      expect(find.byTooltip('Earlier tabs'), findsOneWidget);
      expect(chevron(tester, 'Earlier tabs').onPressed, isNull);
      expect(chevron(tester, 'Later tabs').onPressed, isNotNull);
    });

    testWidgets('a chevron scrolls, and turns the other one on', (
      tester,
    ) async {
      openTabs(30);
      await pump(tester);
      expect(strip(tester).controller!.offset, 0);

      await tester.tap(find.byTooltip('Later tabs'));
      await tester.pumpAndSettle();

      expect(strip(tester).controller!.offset, greaterThan(0));
      expect(chevron(tester, 'Earlier tabs').onPressed, isNotNull);
    });

    testWidgets('the strip starting to overflow throws nothing', (
      tester,
    ) async {
      // The launch bug, reproduced: the strip is built without chevrons while
      // it fits and with them once it does not, which moves the `ListView` to a
      // new slot. For the frame in between, the outgoing viewport is still
      // attached and the controller has two positions —
      // `ScrollController.position` is `positions.single`, so reading it threw
      // `Bad state: Too many elements` out of the chevron's own builder. It ran
      // on every start of the app, and the chevrons never drew.
      openTabs(4);
      await pump(tester);
      expect(find.byTooltip('Later tabs'), findsNothing, reason: 'it fits');

      openTabs(30);
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason: 'crossing into overflow reads a position that is briefly two',
      );
      expect(find.byTooltip('Later tabs'), findsOneWidget);
    });

    testWidgets('and the chevrons still work after that crossing', (
      tester,
    ) async {
      // The other half: disabling them for that one frame is only acceptable
      // because they come back. A guard that left them dead would look exactly
      // like the fix.
      openTabs(4);
      await pump(tester);
      openTabs(30);
      await tester.pumpAndSettle();

      expect(chevron(tester, 'Later tabs').onPressed, isNotNull);
      await tester.tap(find.byTooltip('Later tabs'));
      await tester.pumpAndSettle();
      expect(chevron(tester, 'Earlier tabs').onPressed, isNotNull);
    });

    testWidgets('the picker lists every tab and switches to the one picked', (
      tester,
    ) async {
      final ids = openTabs(30);
      await pump(tester);

      await tester.tap(overflowButton(30));
      await tester.pumpAndSettle();

      expect(find.byType(TabPicker), findsOneWidget);
      expect(find.text('30 tabs'), findsOneWidget);
      // Thirty shells, each now named for the directory it sits in.
      await tester.enterText(find.byType(TextField), 'p27');
      await tester.pumpAndSettle();
      expect(find.text('1 tab'), findsOneWidget);
      await tester.tap(find.text(r'C:\src\p27'));
      await tester.pumpAndSettle();

      expect(
        container.read(terminalSessionsControllerProvider).activeTabId,
        ids[27],
      );
      expect(find.byType(TabPicker), findsNothing);
    });

    testWidgets('closing from the picker closes that tab and no other', (
      tester,
    ) async {
      final ids = openTabs(30);
      await pump(tester);

      await tester.tap(overflowButton(30));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'p27');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(r'Close src/p27'));
      await tester.pumpAndSettle();

      final open = container
          .read(terminalSessionsControllerProvider)
          .tabs
          .map((tab) => tab.id);
      expect(open, isNot(contains(ids[27])));
      expect(open.length, 29);
      // The list is still up, one row shorter, and nothing was switched to.
      expect(find.byType(TabPicker), findsOneWidget);
      expect(find.text('No tab matches.'), findsOneWidget);
    });

    testWidgets('the session in a tab is what the filter finds it by', (
      tester,
    ) async {
      final ids = openTabs(30);
      final paneId = container
          .read(terminalSessionsControllerProvider)
          .tabs[12]
          .focusedPaneId;
      db.server.sessionRows
        ..insert(session(id: 's1', title: 'Fix login redirect'))
        ..updatePaneId('s1', paneId);
      await pump(tester);

      await tester.tap(overflowButton(30));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'login');
      await tester.pumpAndSettle();

      expect(find.text('1 tab'), findsOneWidget);
      await tester.tap(find.textContaining('Fix login redirect'));
      await tester.pumpAndSettle();

      expect(
        container.read(terminalSessionsControllerProvider).activeTabId,
        ids[12],
      );
    });

    testWidgets('stepping tabs scrolls the one you land on into view', (
      tester,
    ) async {
      // What `Ctrl+PageUp`/`Ctrl+PageDown` invoke. Stepping back from the first
      // tab wraps to the last, which is the furthest a step can ever land from
      // where the strip is scrolled to.
      openTabs(30);
      await pump(tester);
      expect(strip(tester).controller!.offset, 0);

      terminals().previousTab();
      await tester.pumpAndSettle();

      final scroll = strip(tester).controller!.position;
      final band = 29 * kMinTabWidth;
      expect(scroll.pixels, lessThanOrEqualTo(band));
      expect(
        scroll.pixels + scroll.viewportDimension,
        greaterThanOrEqualTo(band + kMinTabWidth),
      );

      // And forward again, back to the first tab at the other end.
      terminals().nextTab();
      await tester.pumpAndSettle();
      expect(strip(tester).controller!.offset, 0);
    });

    testWidgets('a hundred tabs in the minimum window still work', (
      tester,
    ) async {
      // 720x560 is the smallest window the app supports. Nothing may overflow
      // (the test fails on a render overflow of its own accord), the way to
      // open another tab may not be pushed off the end, and the picker has to
      // be there — a hundred tabs is the case it exists for.
      openTabs(100);
      await pump(tester, size: const Size(720, 560), chrome: true);

      expect(overflowButton(100), findsOneWidget);
      expect(find.byTooltip(RegExp(r'^New terminal \(')), findsOneWidget);
      // Virtualised: a hundred tabs are not a hundred built chips.
      expect(find.textContaining('src/').evaluate().length, lessThan(100));

      await tester.tap(overflowButton(100));
      await tester.pumpAndSettle();
      expect(find.text('100 tabs'), findsOneWidget);
    });

    testWidgets('a hundred tabs clip nothing and name every control', (
      tester,
    ) async {
      openTabs(100);
      await expectSurvivesWindowMatrix(
        tester,
        build: () => UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(body: WorkbenchView()),
          ),
        ),
        because: 'a hundred sessions is the size the strip is designed for',
      );
    });

    testWidgets('a selected session adds no row to the list', (tester) async {
      // The conversation used to be listed here as a thirty-first tab, and
      // drawn in the strip as a chip, while the toggle beside it did the same
      // job. The list is the terminal's tabs; the conversation is a view of
      // the session, reached from the bar under the surface.
      openTabs(30);
      final paneId = container
          .read(terminalSessionsControllerProvider)
          .tabs
          .first
          .focusedPaneId;
      db.server.sessionRows
        ..insert(session(id: 's1', title: 'Read the report'))
        ..updatePaneId('s1', paneId);
      container.read(selectedSessionIdProvider.notifier).select('s1');
      await pump(tester);

      await tester.tap(overflowButton(30));
      await tester.pumpAndSettle();

      expect(find.text('30 tabs'), findsOneWidget);
      expect(find.text('Conversation'), findsNothing);
      // The session is still what its own tab is named by, which is the half
      // of this that was never the complaint.
      expect(find.textContaining('Read the report'), findsOneWidget);
    });
  });
}
