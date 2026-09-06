import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/agents/data/agent_hook_receiver.dart';
import 'package:karmashala/src/features/agents/data/agent_status_service.dart';
import 'package:karmashala/src/features/agents/domain/agent_status.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/git/domain/diff_stat.dart';
import 'package:karmashala/src/features/notifications/application/agent_status_watcher.dart';
import 'package:karmashala/src/features/notifications/application/attention_inbox.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/notifications/application/session_status_registry.dart';
import 'package:karmashala/src/features/notifications/domain/agent_session_key.dart';
import 'package:karmashala/src/features/notifications/domain/inbox_item.dart';
import 'package:karmashala/src/features/notifications/domain/notification_policy.dart';
import 'package:karmashala/src/features/notifications/domain/notification_request.dart';
import 'package:karmashala/src/features/notifications/domain/notification_settings.dart';
import 'package:karmashala/src/features/notifications/domain/session_attention.dart';
import 'package:karmashala/src/features/notifications/domain/watched_session.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_handoff_service.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session_delivery.dart';
import 'package:karmashala/src/features/sessions/domain/session_fork.dart';
import 'package:karmashala/src/features/sessions/presentation/approval_request_card.dart';
import 'package:karmashala/src/features/sessions/presentation/delivery_strip.dart';
import 'package:karmashala/src/features/sessions/presentation/model_chip.dart';
import 'package:karmashala/src/features/sessions/presentation/permission_mode_chip.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';
import 'package:karmashala/src/features/terminal/domain/pane_liveness.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:karmashala/src/features/terminal/presentation/session_status.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';

/// The minimum window at Windows' largest text step. Not in the shared matrix
/// — adding it there would silently change what every existing surface
/// asserts — so surfaces opt in, and the session bar does because its whole
/// layout rests on one claim about how tall a line of text is.
const minimumWindowHugestText = WindowCell(
  '720x560 @ 2.0x text',
  Size(720, 560),
  textScale: 2.0,
);

/// The pane's own screen, read exactly as `sessionStatusRegistryProvider` reads
/// it for the ambient status pipeline. A function behind a provider, not a
/// family: what it answers changes with every row the agent draws.
final paneTailProvider = Provider<List<String> Function(String)>(
  (ref) => (sessionId) {
    final row = ref.read(sessionDaoProvider).getById(sessionId);
    if (row == null) return const [];
    return sessionTerminalTail(ref, row, agentId: AgentIds.claudeCode);
  },
);

void main() {
  late AppDatabase db;
  late ProviderContainer container;

  /// A checkout nested inside the project's first repository.
  const nestedPath = EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\src\demo\app\nested',
  );

  /// What the status pipeline says about every session, and what git says about
  /// the one on screen. Mutable so a test can set them *before* the first pump,
  /// which is when the overridden providers are first read.
  late AgentActivityStatus agentStatus;
  late List<String> agentEvidence;
  late AgentWaitKind agentWaiting;
  late SessionDelivery delivery;
  late SessionContinuation continuation;

  /// A session that can be handed off or forked — Claude Code forks natively,
  /// so the plan is not a refusal and the strip offers "Continue with…".
  final possible = SessionContinuation(
    targets: const [],
    plan: SessionForkPlan.decide(
      descriptor: AgentRegistry.builtIn.byId(AgentIds.claudeCode),
      agentName: 'Claude Code',
      externalSessionId: 'ext-1',
    ),
  );

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    ProjectDao(db).insert(project());
    RepositoryDao(db)
      ..insert(repository())
      // A clone nested inside the first checkout: the shape behind "the sidebar
      // shows the hub, not the repository I am actually working in".
      ..insert(repository(id: 'r2', name: 'nested', path: nestedPath.path));
    AgentInstallationDao(db).insert(agentInstallation());
    agentStatus = AgentActivityStatus.idle;
    agentEvidence = const [];
    agentWaiting = AgentWaitKind.unrecorded;
    delivery = SessionDelivery.unknown;
    continuation = SessionContinuation(
      targets: const [],
      plan: SessionForkPlan.decide(descriptor: null, agentName: 'Test CLI'),
    );
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        // Both of these poll on a real timer, which would outlive the widget
        // tree and trip flutter_test's pending-timer check. The workbench does
        // not care what they say — only that a session has two renderings.
        sessionTranscriptProvider.overrideWith((ref, id) => Stream.value(const [])),
        // The transcript header offers "open in a system terminal", which
        // *detects* terminals by running real host commands. A unit test must
        // never reach the host for that.
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        // The delivery strip is on both surfaces now, so what git and `gh` are
        // asked is answered here instead of on the host.
        sessionDeliveryProvider.overrideWith((ref, _) async => delivery),
        sessionContinuationProvider.overrideWith((ref, _) => continuation),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => Stream.value(
            AgentStatusReport(
              agentId: AgentIds.claudeCode,
              sessionId: id,
              status: agentStatus,
              observedAt: testTime,
              source: AgentStatusSource.terminalGrid,
              evidence: agentEvidence,
              waiting: agentWaiting,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
  });
  tearDown(() => db.close());

  /// Builds the workbench and settles.
  ///
  /// [size] is a parameter because the session bar's layout is a claim about
  /// widths: the same bar has to hold one action row on a desktop window and
  /// stay two recognisable groups at 720x560.
  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(1200, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: WorkbenchView())),
      ),
    );
    // Settle rather than pump: the transcript surface schedules zero-duration
    // work on mount, and a timer left pending outlives the tree.
    await tester.pumpAndSettle();
  }

  /// Builds the workbench and stops after **one** frame.
  ///
  /// The surface a session opens on is a question about the first frame, not
  /// about where things settle: a workbench that paints the conversation and
  /// then replaces it with the terminal has, from the user's seat, opened both.
  Future<void> pumpOneFrame(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: WorkbenchView())),
      ),
    );
  }

  /// The stack holding the two surfaces: index 0 is the terminal, 1 the chat.
  ///
  /// Found by key rather than through the pane stack: the terminal surface does
  /// not always contain one — a session with no pane of ours gets its empty
  /// state there instead — and a finder that assumed it did could not tell that
  /// case from "the chat is up", which is the whole question here.
  IndexedStack surfaces(WidgetTester tester) =>
      tester.widget<IndexedStack>(find.byKey(kWorkbenchSurfaces));

  /// The delivery strip in the session bar. The conversation has one of its
  /// own on its composer, and only one of the two is ever on screen — the
  /// hidden surface of an IndexedStack is offstage to a finder — but the flag
  /// says which host is which without depending on that.
  final hostedStrip = find.byWidgetPredicate(
    (widget) => widget is DeliveryStrip && widget.hostedOnTerminal,
  );

  /// Asserts [control] is drawn under the terminal rather than up in the tab
  /// strip, which is the whole of the reported complaint about the chip.
  void expectBelowTheTerminal(WidgetTester tester, Finder control) {
    expect(
      tester.getTopLeft(control).dy,
      greaterThanOrEqualTo(
        tester.getBottomLeft(find.byType(TerminalPaneStack)).dy,
      ),
      reason: 'this belongs to the bar under the terminal, not to the strip',
    );
  }

  /// A session running in a pane of ours — the only kind that has two views.
  String seedSessionInAPane({
    String id = 's1',
    String title = 'Session',
    EnvironmentPath? worktree,
  }) {
    final terminals = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    terminals.openTab(TerminalProfile.powerShell);
    final paneId = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .layout
        .panes
        .single;
    final dao = SessionDao(db);
    dao.insert(
      session(
        id: id,
        title: title,
        useWorktree: worktree != null,
        worktree: worktree,
      ),
    );
    dao.updatePaneId(id, paneId);
    return paneId;
  }

  testWidgets('with nothing selected the workbench is the terminal', (
    tester,
  ) async {
    await pump(tester);

    expect(find.byType(TerminalPaneStack), findsOneWidget);
    expect(find.byType(SessionTranscriptView), findsNothing);
    // No dock chrome survived the move.
    expect(find.byTooltip('Hide terminal (Ctrl+`)'), findsNothing);
  });

  testWidgets('a selected session adds no tab of its own', (tester) async {
    // The report: one tap in the Explorer grew a conversation tab *and* a
    // Terminal/Chat switch — two pieces of chrome for one thing, in the same
    // row. The strip is terminal tabs; the way to the conversation is the
    // labelled toggle in the bar under the surface.
    seedSessionInAPane(title: 'Refactor the parser');
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await pump(tester);

    expect(find.text('PowerShell'), findsOneWidget);
    expect(find.byTooltip('Conversation · Refactor the parser'), findsNothing);
    expect(find.byTooltip('Close conversation'), findsNothing);
    expect(find.byTooltip('Chat view'), findsOneWidget);
  });

  testWidgets('selecting a session opens its terminal, not its chat', (
    tester,
  ) async {
    // The Loop 85 inversion. This used to assert the opposite: a selection
    // switched the workbench to the conversation, which made the secondary
    // view the one every session opened on.
    final paneId = seedSessionInAPane(title: 'Refactor the parser');
    await pump(tester);
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await tester.pumpAndSettle();

    expect(container.read(terminalVisibleProvider), isTrue);
    // Not merely "the terminal is up": the session's own pane is the focused
    // one, so what is on screen is that session.
    expect(
      container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .focusedPaneId,
      paneId,
    );
    // A rendering choice, never a lifecycle one.
    final instance = container
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(paneId);
    expect((instance! as FakeTerminalInstance).disposed, isFalse);
  });

  testWidgets('selecting a session reaches its pane in a background tab', (
    tester,
  ) async {
    final paneId = seedSessionInAPane();
    // Another tab on top of it: the selection has to walk back to the session's
    // own pane rather than leave whatever was showing.
    container
        .read(terminalSessionsControllerProvider.notifier)
        .openTab(TerminalProfile.powerShell);
    await pump(tester);
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await tester.pumpAndSettle();

    expect(
      container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .focusedPaneId,
      paneId,
    );
  });

  testWidgets('a session with no pane of ours still lands on the terminal', (
    tester,
  ) async {
    // An imported session resumed elsewhere, a session opened in an external
    // terminal, or one whose pane has been ended. This used to fall back to the
    // conversation, which is how a tap could open the chat interface; the
    // terminal surface now says what is true instead of showing a tab that
    // belongs to some other session.
    SessionDao(db).insert(session(title: 'Read the report'));
    await pump(tester);
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await tester.pumpAndSettle();

    expect(container.read(terminalVisibleProvider), isTrue);
    expect(find.byType(TerminalPaneStack), findsNothing);
    expect(
      find.textContaining('No terminal of ours is running this session'),
      findsOneWidget,
    );
    // ...and the conversation is still one labelled tap away. The bar is
    // offered for a selected session with no pane of ours precisely because
    // nothing lands on the transcript by itself any more: keyed off the pane
    // the way the rest of the bar is, this session would have no way to it.
    expect(find.byTooltip('Chat view'), findsOneWidget);
    expect(tester.widget<DeliveryStrip>(hostedStrip).sessionId, 's1');

    await tester.tap(find.byTooltip('Chat view'));
    await tester.pumpAndSettle();
    expect(surfaces(tester).index, 1);
  });

  testWidgets('a pane that has been ended stops being a surface', (
    tester,
  ) async {
    // The row keeps its `pane_id` after the pane is gone, so the id alone would
    // send the workbench to a terminal that is not there.
    final paneId = seedSessionInAPane();
    container
        .read(terminalSessionsControllerProvider.notifier)
        .closeTab(
          container.read(terminalSessionsControllerProvider).tabs.single.id,
          detach: false,
        );
    await pump(tester);
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await tester.pumpAndSettle();

    expect(
      container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(paneId),
      isNull,
    );
    expect(container.read(terminalVisibleProvider), isTrue);
    expect(
      find.textContaining('No terminal of ours is running this session'),
      findsOneWidget,
    );
  });

  testWidgets('the toggle is labelled, and still reaches the conversation', (
    tester,
  ) async {
    seedSessionInAPane();
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await pump(tester);

    // Words, not only a chord and a hover: the terminal is where a session
    // opens now, so the way to its conversation has to be readable.
    expect(find.widgetWithText(Tooltip, 'Chat'), findsOneWidget);
    expect(find.widgetWithText(Tooltip, 'Terminal'), findsOneWidget);
    expect(container.read(terminalVisibleProvider), isTrue);
    // And it is chrome under the surface now, beside the rest of this
    // session's controls, rather than a switch in the row of tabs.
    expectBelowTheTerminal(tester, find.byTooltip('Chat view'));

    await tester.tap(find.byTooltip('Chat view'));
    await tester.pumpAndSettle();

    expect(container.read(terminalVisibleProvider), isFalse);
    expect(find.byType(SessionTranscriptView), findsOneWidget);

    await tester.tap(find.byTooltip('Terminal view'));
    await tester.pumpAndSettle();
    expect(container.read(terminalVisibleProvider), isTrue);
  });

  testWidgets('a pane reached only by its tab still offers the Chat half', (
    tester,
  ) async {
    // Loop 85 §7: with nothing selected in the Explorer but an agent pane
    // focused, the permission chip and the delivery strip worked — they follow
    // the pane — while the toggle was absent, because the toggle and the chat
    // surface both read the *selection*. So an agent you reached by activating
    // its terminal tab had every session control except the way to its
    // transcript.
    seedSessionInAPane(title: 'Refactor the parser');
    // A shell on top of it, so the agent's tab is not the one in front and the
    // only way to it is the strip.
    container
        .read(terminalSessionsControllerProvider.notifier)
        .openTab(TerminalProfile.powerShell);
    await pump(tester);

    expect(find.byTooltip('Chat view'), findsNothing, reason: 'a shell tab');

    // The tap the user makes: the agent's tab in the strip, nothing else.
    await tester.tap(find.byType(TerminalTabChip).first);
    await tester.pumpAndSettle();

    expect(find.byTooltip('Chat view'), findsOneWidget);
    expect(
      container.read(selectedSessionIdProvider),
      isNull,
      reason: 'the toggle is offered by following the pane, not by selecting',
    );

    await tester.tap(find.byTooltip('Chat view'));
    await tester.pumpAndSettle();

    expect(surfaces(tester).index, 1, reason: 'the conversation is up');
    expect(
      tester
          .widget<SessionTranscriptView>(find.byType(SessionTranscriptView))
          .sessionId,
      's1',
      reason: 'and it is this pane\'s session, not whatever was selected',
    );
  });

  testWidgets('the way to that transcript does not bounce back to the pane', (
    tester,
  ) async {
    // The trap the follow-up recorded: the obvious fix is to *select* the
    // focused pane's session on the way to chat, and selecting fires the
    // listener that opens the session's terminal — so the toggle would fight
    // the surface it just left. Nothing here writes the selection, so there is
    // no second write to order against the first; this pins that.
    final paneId = seedSessionInAPane();
    await pump(tester);
    await tester.tap(find.byTooltip('Chat view'));
    await tester.pumpAndSettle();
    expect(surfaces(tester).index, 1);

    // Two of the things the app publishes constantly while a session runs. A
    // fix that selected the pane's session to make the toggle appear would
    // have armed the listener that opens that session's terminal, and either
    // of these would then have taken the surface back.
    container.read(sessionsRevisionProvider.notifier).bump();
    await tester.pumpAndSettle();
    container
        .read(terminalSessionsControllerProvider.notifier)
        .focusPane(paneId);
    await tester.pumpAndSettle();

    expect(container.read(selectedSessionIdProvider), isNull);
    expect(container.read(terminalVisibleProvider), isFalse);
    expect(surfaces(tester).index, 1, reason: 'still the conversation');

    // What does take it back is a deliberate request to *see* a tab, which is
    // the whole of what the strip's own tap means.
    await tester.tap(find.byType(TerminalTabChip).first);
    await tester.pumpAndSettle();

    expect(container.read(terminalVisibleProvider), isTrue);
    expect(surfaces(tester).index, 0);
  });

  group('a paneless selection does not hold the terminal hostage', () {
    /// Two tabs, and a **third** session selected that nothing of ours runs.
    ///
    /// The reported shape: "after closing a session with end session on a tab,
    /// other tabs are not accessible cannot switch to other tabs". The
    /// terminal's own state was healthy throughout — two live tabs, nothing
    /// detached — so the failure was entirely in which surface the workbench
    /// chose to draw over them.
    String seedTwoTabsAndAPanelessSelection() {
      final paneId = seedSessionInAPane(title: 'Refactor the parser');
      container
          .read(terminalSessionsControllerProvider.notifier)
          .openTab(TerminalProfile.powerShell);
      SessionDao(
        db,
      ).insert(session(id: 's3', title: 'Audit and improve Karmashala app'));
      container.read(selectedSessionIdProvider.notifier).select('s3');
      return paneId;
    }

    testWidgets('activating a tab through the strip shows that tab', (
      tester,
    ) async {
      seedTwoTabsAndAPanelessSelection();
      await pump(tester);

      // The stuck screen: the empty state for a session that is neither tab,
      // drawn *instead of* the pane stack, with no chip marked active.
      expect(
        find.textContaining('No terminal of ours is running this session'),
        findsOneWidget,
      );
      expect(find.byType(TerminalPaneStack), findsNothing);
      expect(
        tester
            .widgetList<TerminalTabChip>(find.byType(TerminalTabChip))
            .any((chip) => chip.selected),
        isFalse,
        reason: 'no terminal tab is on screen, so none of them says it is',
      );

      // The tap the user makes — the strip's own chip, not the controller.
      await tester.tap(find.byType(TerminalTabChip).first);
      await tester.pumpAndSettle();

      expect(
        find.byType(TerminalPaneStack),
        findsOneWidget,
        reason: 'a tab tap is a request to see that tab, and it wins',
      );
      expect(
        find.textContaining('No terminal of ours is running this session'),
        findsNothing,
      );
      expect(
        tester
            .widget<TerminalTabChip>(find.byType(TerminalTabChip).first)
            .selected,
        isTrue,
        reason: 'and the tab that is on screen says so',
      );
    });

    testWidgets('the empty state comes back when its session is picked again', (
      tester,
    ) async {
      // Releasing the selection has to leave the way back open. Clearing it —
      // rather than out-voting it with a second mode — is what makes picking
      // the same row again a *change*, so the workbench opens it exactly as it
      // did the first time.
      seedTwoTabsAndAPanelessSelection();
      await pump(tester);
      await tester.tap(find.byType(TerminalTabChip).first);
      await tester.pumpAndSettle();
      expect(container.read(selectedSessionIdProvider), isNull);

      container.read(selectedSessionIdProvider.notifier).select('s3');
      await tester.pumpAndSettle();

      expect(
        find.textContaining('No terminal of ours is running this session'),
        findsOneWidget,
      );
    });

    testWidgets('a selection that has a pane is left alone', (tester) async {
      // Only the selection that is *hijacking* the surface is released. One
      // the user can actually see is the session they are working in, and
      // activating a tab must not quietly drop it — the toggle to its
      // conversation is offered off the back of it.
      seedSessionInAPane();
      container
          .read(terminalSessionsControllerProvider.notifier)
          .openTab(TerminalProfile.powerShell);
      container.read(selectedSessionIdProvider.notifier).select('s1');
      await pump(tester);

      await tester.tap(find.byType(TerminalTabChip).first);
      await tester.pumpAndSettle();

      expect(container.read(selectedSessionIdProvider), 's1');
      expect(find.byType(TerminalPaneStack), findsOneWidget);
    });
  });

  testWidgets('the strip draws no active tab while that conversation is up', (
    tester,
  ) async {
    // The strip may only mark a tab active while panes are what the workbench
    // is showing. With nothing selected that used to be unconditional, because
    // nothing selected meant there was no second surface to be on.
    seedSessionInAPane();
    await pump(tester);
    expect(
      tester.widget<TerminalTabChip>(find.byType(TerminalTabChip)).selected,
      isTrue,
    );

    await tester.tap(find.byTooltip('Chat view'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TerminalTabChip>(find.byType(TerminalTabChip)).selected,
      isFalse,
      reason: 'no terminal tab is on screen, so none of them may say it is',
    );
  });

  testWidgets('the two surfaces switch inside one IndexedStack', (
    tester,
  ) async {
    // The Loop 26 property, one level above the terminal's own tabs: an
    // IndexedStack keeps the hidden surface built and unpainted, which is what
    // `pane_layout_view_test` proves about IndexedStack and what lets the chat
    // view keep its scroll position while a terminal is up.
    //
    // **Once it has been asked for.** A stack that always held both meant every
    // tap on a session mounted its conversation behind the terminal, and that
    // costs a CLI store scan plus a whole-transcript parse — see
    // `session_switch_cost_test.dart`. Until the toggle is pressed there is one
    // surface, and nothing hidden to keep alive.
    seedSessionInAPane();
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await pump(tester);

    IndexedStack surfaces() =>
        tester.widget<IndexedStack>(find.byKey(kWorkbenchSurfaces));

    expect(
      surfaces().children.length,
      1,
      reason: 'only the terminal is asked for',
    );
    expect(surfaces().index, 0, reason: 'the terminal is showing');

    await tester.tap(find.byTooltip('Chat view'));
    await tester.pumpAndSettle();
    expect(surfaces().index, 1, reason: 'now the conversation is');
    expect(surfaces().children.length, 2);

    // ...and back, with both still alive: that is what the stack is for.
    await tester.tap(find.byTooltip('Terminal view'));
    await tester.pumpAndSettle();
    expect(surfaces().index, 0);
    expect(surfaces().children.length, 2, reason: 'both surfaces stay alive');
  });

  testWidgets('with one surface there is no stack to pay for', (tester) async {
    // Nothing selected: the workbench is only the terminal, so it must not wrap
    // it in a switcher that has nothing to switch to.
    await pump(tester);

    expect(
      find.ancestor(
        of: find.byType(TerminalPaneStack),
        matching: find.byType(IndexedStack),
      ),
      findsNothing,
    );
  });

  testWidgets('an agent pane carries its permission chip under the terminal', (
    tester,
  ) async {
    // No selection: this is the terminal view on its own, which is where the
    // chip did not exist. The mode was readable only from the chat composer,
    // so the one control the user needs before letting an agent run was
    // invisible on the surface they were watching it on. It then sat in the
    // tab strip — the one session control up there while every other one was
    // below — which is the second half of the report.
    seedSessionInAPane();
    await pump(tester);

    expect(find.byType(PermissionModeChip), findsOneWidget);
    expectBelowTheTerminal(tester, find.byType(PermissionModeChip));

    // A plain shell tab has no agent and no mode, so it draws nothing.
    container
        .read(terminalSessionsControllerProvider.notifier)
        .openTab(TerminalProfile.powerShell);
    await tester.pumpAndSettle();

    expect(find.byType(PermissionModeChip), findsNothing);
  });

  testWidgets('both views name the same session, so they cannot disagree', (
    tester,
  ) async {
    seedSessionInAPane();
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await pump(tester);

    String shownSessionId() => tester
        .widget<PermissionModeChip>(find.byType(PermissionModeChip))
        .sessionId;

    // One chip is showing on either surface, and it is the same session on
    // both: the strip's while the terminal is up, the composer's while the
    // conversation is. Two controls over one record, never two records.
    expect(shownSessionId(), 's1');

    await tester.tap(find.byTooltip('Chat view'));
    await tester.pumpAndSettle();

    expect(shownSessionId(), 's1');
  });

  testWidgets('the terminal carries the delivery lifecycle, handoff and fork', (
    tester,
  ) async {
    // The reason the chat view could not stay the primary surface: everything
    // you do *with* a session — commit, push, hand it to another agent, fork it
    // — lived only there, so the terminal was a session you could watch and not
    // steer.
    delivery = const SessionDelivery(
      branch: 'work',
      baseBranch: 'origin/main',
      hasRemote: true,
      dirtyFiles: 2,
      aheadOfBase: 3,
      hasWorktree: true,
    );
    continuation = possible;
    seedSessionInAPane();
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await pump(tester);

    expect(container.read(terminalVisibleProvider), isTrue);
    expect(find.byType(DeliveryStrip), findsOneWidget);
    expect(find.text('Working'), findsOneWidget);
    expect(find.text('work'), findsOneWidget);
    expect(find.text('2 uncommitted'), findsOneWidget);
    expect(find.text('Commit'), findsOneWidget);
    // Handoff and fork, the two the brief named, behind the same one dialog the
    // conversation opens.
    expect(find.text('Continue with…'), findsOneWidget);
  });

  group('the session bar is a state line over one action row', () {
    /// Everything the bar can hold at once: a stage, a long branch name, a
    /// diff, a dirty tree, a base it is ahead of, four actions and both ends.
    ///
    /// The reports this answers, in order: "terminal bottom the buttons
    /// doesn't sit well with the design", "when all the buttons are below why
    /// is permission picker above with the tabs list", "bottom bar still looks
    /// weird design wise". The last one is a layout complaint — one `Wrap`
    /// held the facts and the buttons together, so they sorted themselves by
    /// whatever fitted and `Commit` ended up a row above its three siblings.
    void seedTheFullestBar() {
      delivery = const SessionDelivery(
        branch: 'session/fix-the-login-form-validation',
        baseBranch: 'origin/main',
        hasRemote: true,
        dirtyFiles: 1,
        lines: DiffStat(added: 59, removed: 6, files: 7),
        aheadOfBase: 2,
        hasWorktree: true,
      );
      continuation = possible;
      seedSessionInAPane();
      container.read(selectedSessionIdProvider.notifier).select('s1');
    }

    /// The four facts and the four actions, as the user reads them.
    const facts = [
      'Working',
      'session/fix-the-login-form-validation',
      '+59 −6',
      '1 uncommitted',
      '2 ahead of origin/main',
    ];
    const actions = [
      'Commit',
      'Push',
      'Open PR',
      'Run tests',
      'Archive worktree',
      'Continue with…',
    ];

    Finder inTheBar(String text) => find.descendant(
      of: find.byType(DeliveryStrip),
      matching: find.text(text),
    );

    testWidgets('the facts sit above the buttons, never among them', (
      tester,
    ) async {
      seedTheFullestBar();
      await pump(tester);

      // Measured, not asserted by presence: the complaint was about where
      // these landed, and only geometry can answer that. Every fact ends
      // above where the first button starts, so no width can interleave them.
      final lowestFact = facts
          .map((text) => tester.getBottomLeft(find.text(text)).dy)
          .reduce((a, b) => a > b ? a : b);
      final highestAction = actions
          .map((text) => tester.getTopLeft(inTheBar(text)).dy)
          .reduce((a, b) => a < b ? a : b);
      expect(
        lowestFact,
        lessThanOrEqualTo(highestAction),
        reason: 'the state line is a line, not the first item in the row',
      );
    });

    testWidgets('every control on the action row shares one centre-line', (
      tester,
    ) async {
      seedTheFullestBar();
      await pump(tester, size: desktopWindow.size);

      // The primary and its peers first: `Commit` was stranded up beside the
      // branch name, a row above the three buttons it belongs with.
      final line = tester.getCenter(inTheBar('Commit')).dy;
      for (final label in actions) {
        expect(
          tester.getCenter(inTheBar(label)).dy,
          moreOrLessEquals(line, epsilon: 0.5),
          reason: '$label is not on the action row',
        );
      }

      // And the two ends, which used to be centred against a two-row block and
      // therefore lined up with nothing. They are the same height as the
      // actions by construction, so this is exact rather than approximate.
      expect(
        tester.getCenter(find.byType(PermissionModeChip)).dy,
        moreOrLessEquals(line, epsilon: 0.5),
        reason: 'the permission control floats above the actions',
      );
      expect(
        tester.getCenter(find.byTooltip('Terminal view')).dy,
        moreOrLessEquals(line, epsilon: 0.5),
        reason: 'the view toggle floats above the actions',
      );
    });

    testWidgets('the model is chosen from the session, not the window', (
      tester,
    ) async {
      seedTheFullestBar();
      await pump(tester, size: desktopWindow.size);

      // It used to live in the window's status bar beside the account quota,
      // which put a per-session control among window-wide ones — and left it
      // describing whichever session the app believed was focused. It belongs
      // with the other answer to "how does this session run": its permission
      // mode, on the same centre-line as the actions it sits beside.
      final chip = find.byType(SessionModelChip);
      expect(chip, findsOneWidget);
      expect(
        tester.getCenter(chip).dy,
        moreOrLessEquals(tester.getCenter(inTheBar('Commit')).dy, epsilon: 0.5),
      );
      expect(
        tester.getRect(chip).left,
        greaterThan(tester.getRect(find.byType(PermissionModeChip)).right - 1),
        reason: 'beside the permission mode, not before it',
      );
    });

    testWidgets('and steps aside when the bar has no room for it', (
      tester,
    ) async {
      seedTheFullestBar();
      await pump(tester, size: minimumWindow.size);

      // At 720px the row is already 14px over with this chip squeezed to its
      // glyphs. Absent beats crushed: the chat surface carries the same chip at
      // full width, so a narrow terminal loses a shortcut rather than the
      // control — and the actions keep the single line the complaint behind
      // this bar was about.
      expect(find.byType(SessionModelChip), findsNothing);
      expect(find.byType(PermissionModeChip), findsOneWidget);
    });

    testWidgets('exactly one action is filled, and it is the next step', (
      tester,
    ) async {
      // One weight for the group, one exception. `Commit` is primary while
      // there is something to commit; the rest are peers, and nothing else in
      // the bar borrows the emphasis.
      seedTheFullestBar();
      await pump(tester);

      final scheme = Theme.of(
        tester.element(find.byType(PermissionModeChip)),
      ).colorScheme;
      Color? fillBehind(String label) {
        final box = tester.widget<Container>(
          find
              .ancestor(of: inTheBar(label), matching: find.byType(Container))
              .first,
        );
        return (box.decoration! as BoxDecoration).color;
      }

      expect(fillBehind('Commit'), scheme.primaryContainer);
      for (final label in actions.where((label) => label != 'Commit')) {
        expect(fillBehind(label), isNull, reason: '$label is not the primary');
      }
    });

    testWidgets('the groups survive the narrowest window', (tester) async {
      // At 720x560 the actions run out of room and wrap. What must not happen
      // is the old behaviour: a second run that starts with a fact and
      // finishes with a button.
      seedTheFullestBar();
      await pump(tester, size: minimumWindow.size);

      final lowestFact = facts
          .map((text) => tester.getBottomLeft(find.text(text)).dy)
          .reduce((a, b) => a > b ? a : b);
      final runs = actions
          .map((text) => tester.getCenter(inTheBar(text)).dy)
          .toList();
      final firstRun = runs.reduce((a, b) => a < b ? a : b);
      expect(
        lowestFact,
        lessThanOrEqualTo(
          actions
              .map((text) => tester.getTopLeft(inTheBar(text)).dy)
              .reduce((a, b) => a < b ? a : b),
        ),
        reason: 'the two groups still do not interleave',
      );

      // The ends hold the first run's line rather than drifting to the middle
      // of the block — the whole reason the row is aligned to its start.
      expect(
        tester.getCenter(find.byType(PermissionModeChip)).dy,
        moreOrLessEquals(firstRun, epsilon: 0.5),
      );
      expect(
        tester.getCenter(find.byTooltip('Terminal view')).dy,
        moreOrLessEquals(firstRun, epsilon: 0.5),
      );
    });
  });

  testWidgets('the bar survives the minimum window and larger text', (
    tester,
  ) async {
    // Everything the bar can hold at once: a permission mode, a stage, a long
    // branch, a diff, six actions and the toggle. It wraps rather than
    // clipping, and every control in it still has a name for Narrator to read.
    delivery = const SessionDelivery(
      branch: 'session/fix-the-login-form-validation',
      baseBranch: 'origin/main',
      hasRemote: true,
      dirtyFiles: 2,
      lines: DiffStat(added: 59, removed: 6, files: 7),
      aheadOfBase: 3,
      hasWorktree: true,
    );
    continuation = possible;
    seedSessionInAPane();
    container.read(selectedSessionIdProvider.notifier).select('s1');

    await expectSurvivesWindowMatrix(
      tester,
      build: () => UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: WorkbenchView())),
      ),
      // The default matrix stops at 1.3x. The bar is built on every control in
      // it being one line of `labelSmall` tall, and a fixed-height row is
      // exactly what survives 1.3x and breaks at Windows' largest step — so
      // this surface is asked the question the setting can actually ask.
      matrix: const [...windowMatrix, minimumWindowHugestText],
      because: 'the bar is the busiest row of chrome in the window',
    );
  });

  /// Puts a session's agent in front of an open approval prompt.
  void seedAPendingApproval() {
    agentStatus = AgentActivityStatus.awaitingApproval;
    agentEvidence = const ['Do you want to make this edit to main.dart?'];
    agentWaiting = AgentWaitKind.approval;
  }

  testWidgets('a pending approval draws no card on the terminal surface', (
    tester,
  ) async {
    // The card used to sit under the panes, and this used to assert it was
    // there. What it answers is the prompt the agent draws in the terminal
    // directly above it — already answerable by typing there — so the surface
    // carried a second copy of a control it hosts. Gone on purpose, which is
    // what this now pins.
    seedAPendingApproval();
    seedSessionInAPane();
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await pump(tester);

    expect(find.byType(ApprovalRequestCard), findsNothing);
    expect(find.textContaining('is waiting for you'), findsNothing);
    expect(find.textContaining('Do you want to make this edit'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Approve'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'Deny'), findsNothing);
    // The rows it took are the terminal's again: the surface is the panes and
    // nothing else, whether or not something is waiting.
    expect(
      tester.getSize(find.byType(TerminalPaneStack)).height,
      tester.getSize(find.byKey(kWorkbenchSurfaces)).height,
    );
  });

  testWidgets('the conversation still draws the approval the terminal drops', (
    tester,
  ) async {
    seedAPendingApproval();
    seedSessionInAPane();
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await pump(tester);
    expect(find.byType(ApprovalRequestCard), findsNothing);

    await tester.tap(find.byTooltip('Chat view'));
    await tester.pumpAndSettle();

    // Unchanged here, and for the reason the terminal does not need it: the
    // conversation has no other way to see the prompt, so it quotes the agent,
    // offers the keys and offers the way to the terminal.
    expect(find.byType(ApprovalRequestCard), findsOneWidget);
    expect(find.textContaining('is waiting for you'), findsOneWidget);
    expect(
      find.textContaining('Do you want to make this edit'),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, 'Approve'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Terminal view'), findsOneWidget);
  });

  testWidgets('the terminal surface survives the window matrix without it', (
    tester,
  ) async {
    // Dropping a row from a surface is a layout change, so the surface is
    // asked the same question every other one is.
    seedAPendingApproval();
    seedSessionInAPane();
    container.read(selectedSessionIdProvider.notifier).select('s1');

    await expectSurvivesWindowMatrix(
      tester,
      build: () => UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: WorkbenchView())),
      ),
      because: 'the panes now run to the session bar',
    );
  });

  testWidgets(
    'an approval nobody is looking at still reaches the tray, the toast and '
    'the inbox with no card under the terminal',
    (tester) async {
      // The one real risk in dropping the card: it was the loudest sign that a
      // session had stopped for the user. Nothing that *finds* an approval for
      // you ever read it — the ambient pipeline reads the pane's own screen —
      // and this is what says so, end to end, for a pane-surface session.
      //
      // The app-wide projection is set to agree with the pane the local
      // registry below reads, so the tab strip's own answer can be asserted in
      // the same breath as the tray's.
      agentStatus = AgentActivityStatus.awaitingApproval;
      final paneId = seedSessionInAPane();
      // Elsewhere, which is the case the inbox exists for: an approval that
      // lands while the window is behind something else.
      container.read(windowFocusedProvider.notifier).set(false);
      await pump(tester);
      expect(find.byType(ApprovalRequestCard), findsNothing);

      const watched = WatchedSession(
        key: AgentSessionKey(AgentIds.claudeCode, 's1'),
        label: 'Session',
        openId: 's1',
        imported: false,
      );
      final tail = container.read(paneTailProvider);
      var attention = <SessionAttention>[];
      final notified = <PendingNotification>[];
      final registry = SessionStatusRegistry(
        statusService: AgentStatusService(
          registry: AgentRegistry.builtIn,
          hookReports: AgentHookReports(),
          clock: FixedClock(testTime),
        ),
        agents: AgentRegistry.builtIn,
        loadSessions: () => const [watched],
        clock: FixedClock(testTime),
        readTail: (session) => tail(session.openId),
      );
      addTearDown(registry.dispose);
      final watcher = AgentStatusWatcher(
        registry: registry,
        readSettings: () => const NotificationSettings(),
        isWindowFocused: () => container.read(windowFocusedProvider),
        visibleSessionIds: () => const {},
        onAttention: (next) => attention = next,
        onNotify: notified.add,
        // Wired exactly as `agentStatusWatcherProvider` wires it, so the count
        // asserted below is the one the status bar and the rail badge read.
        onInbox: container.read(attentionInboxProvider.notifier).apply,
      );
      addTearDown(watcher.dispose);

      final terminal = container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(paneId)!
          .terminal;
      terminal.write('  esc to interrupt  \r\n');
      await watcher.poll();
      expect(watcher.lastStatusOf(watched.key), AgentActivityStatus.working);

      // Cleared first: the tail is the bottom of the screen, and leaving the
      // working marker up there would be two answers at once.
      terminal.write('\x1b[2J\x1b[H  Enter to confirm  \r\n');
      await watcher.poll();

      expect(attention.single.kind, AttentionKind.needsInput);
      expect(attention.single.menuLabel, 'Session — needs approval');
      expect(notified.single.reason, NotificationReason.needsInput);
      expect(container.read(attentionCountProvider), 1);
      expect(
        container.read(attentionInboxProvider).items.single.kind,
        InboxItemKind.needsApproval,
      );
      // And the projection every status badge draws — the Explorer's row dot
      // included — still reads the prompt off the pane.
      expect(
        registry.reportForOpenId('s1')?.status,
        AgentActivityStatus.awaitingApproval,
      );
      // And the tab says so. The strip used to be able to report only whether
      // a *process* existed — which is all [TabLivenessDot] is, and it says it
      // by being absent — so an approval nobody was looking at was invisible in
      // the one place you look when several agents are running. The pane is
      // still live, so liveness has nothing to say and yields its slot to the
      // agent's own status, read from the same projection the badge draws.
      expect(
        container.read(terminalPaneLivenessProvider(paneId)),
        PaneLiveness.live,
      );
      expect(find.byType(TabLivenessDot), findsNothing);
      expect(
        tester
            .widget<TabAgentStatusDot>(find.byType(TabAgentStatusDot))
            .status,
        AgentActivityStatus.awaitingApproval,
      );
    },
  );

  testWidgets('an agent that merely messaged is offered no keys', (
    tester,
  ) async {
    // The live complaint: a finished turn nudged the user and the app offered
    // Approve — a button that types Enter into a prompt with nothing open. The
    // dock this was reported against is gone, so the case is asked of the
    // surface that still carries the card.
    agentStatus = AgentActivityStatus.awaitingApproval;
    agentEvidence = const ['Claude is waiting for your input'];
    agentWaiting = AgentWaitKind.input;
    seedSessionInAPane();
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await pump(tester);
    expect(find.textContaining('waiting for your input'), findsNothing);

    await tester.tap(find.byTooltip('Chat view'));
    await tester.pumpAndSettle();

    // The headline, not the quoted message: both say it, and only one of them
    // is the app speaking.
    expect(
      find.textContaining('Claude Code is waiting for your input'),
      findsOneWidget,
    );
    expect(find.textContaining('nothing to approve'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Approve'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'Deny'), findsNothing);
  });

  testWidgets('a shell tab gets no session controls at all', (tester) async {
    // The dock follows the pane on screen, like the permission chip: a plain
    // shell has no session, so there is nothing to draw and nothing to hide.
    seedSessionInAPane();
    await pump(tester);
    expect(find.byType(DeliveryStrip), findsOneWidget);

    container
        .read(terminalSessionsControllerProvider.notifier)
        .openTab(TerminalProfile.powerShell);
    await tester.pumpAndSettle();

    expect(find.byType(DeliveryStrip), findsNothing);
    expect(find.byType(ApprovalRequestCard), findsNothing);
  });

  testWidgets('the dock follows the terminal tab, not the tree selection', (
    tester,
  ) async {
    // Two sessions, each in its own tab. Switching tabs changes which agent is
    // on screen, so the controls under it have to change with it or they would
    // act on a session the user is not looking at.
    seedSessionInAPane(id: 's1', title: 'First');
    final second = seedSessionInAPane(id: 's2', title: 'Second');
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await pump(tester);

    expect(
      tester.widget<DeliveryStrip>(find.byType(DeliveryStrip)).sessionId,
      's1',
    );

    container
        .read(terminalSessionsControllerProvider.notifier)
        .focusPane(second);
    await tester.pumpAndSettle();

    expect(
      tester.widget<DeliveryStrip>(find.byType(DeliveryStrip)).sessionId,
      's2',
    );
  });

  testWidgets('the side panel follows the session in the terminal tab', (
    tester,
  ) async {
    // The reported bug: the panel described whatever row was last clicked in
    // the Explorer — for a hub project, the hub — while the user was typing
    // into an agent working in a clone underneath it. Note `s2`'s row still
    // says `r1`; what decides is where its agent works.
    seedSessionInAPane(id: 's1', title: 'Hub');
    final nested = seedSessionInAPane(
      id: 's2',
      title: 'Nested',
      worktree: nestedPath,
    );
    await pump(tester);
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await tester.pumpAndSettle();

    expect(container.read(selectedRepositoryIdProvider), 'r1');

    container
        .read(terminalSessionsControllerProvider.notifier)
        .focusPane(nested);
    await tester.pumpAndSettle();

    expect(container.read(selectedRepositoryIdProvider), 'r2');
  });

  testWidgets('an Explorer choice holds until the active session changes', (
    tester,
  ) async {
    // Switching must stay possible: a deliberate click is not overruled by the
    // session already on screen, only by moving to a different one.
    seedSessionInAPane(id: 's1', title: 'Hub');
    final nested = seedSessionInAPane(
      id: 's2',
      title: 'Nested',
      worktree: nestedPath,
    );
    await pump(tester);
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await tester.pumpAndSettle();

    container.read(selectedRepositoryIdProvider.notifier).select('r2');
    await tester.pumpAndSettle();
    expect(
      container.read(selectedRepositoryIdProvider),
      'r2',
      reason: 'the session on screen did not change, so nothing overrode it',
    );

    container
        .read(terminalSessionsControllerProvider.notifier)
        .focusPane(nested);
    await tester.pumpAndSettle();
    expect(container.read(selectedRepositoryIdProvider), 'r2');

    // ...and back: moving to a session in the other checkout does move it.
    container
        .read(terminalSessionsControllerProvider.notifier)
        .focusPane(container.read(sessionDaoProvider).getById('s1')!.paneId!);
    await tester.pumpAndSettle();
    expect(container.read(selectedRepositoryIdProvider), 'r1');
  });

  testWidgets('a tab with no session leaves the Explorer in charge', (
    tester,
  ) async {
    seedSessionInAPane(id: 's1', title: 'Hub');
    await pump(tester);
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await tester.pumpAndSettle();
    expect(container.read(selectedRepositoryIdProvider), 'r1');

    container.read(selectedRepositoryIdProvider.notifier).select('r2');
    container
        .read(terminalSessionsControllerProvider.notifier)
        .openTab(TerminalProfile.powerShell);
    await tester.pumpAndSettle();

    expect(
      container.read(selectedRepositoryIdProvider),
      'r2',
      reason: 'a shell tab is not a session and must not steer the panel',
    );
  });

  testWidgets('a pane arriving for the selected session takes the surface', (
    tester,
  ) async {
    // The reported regression. `ExplorerActions.openNative` selects the row
    // *first* and only then reveals or resumes it, so the workbench chose the
    // surface while the session still had no pane — conversation — and the
    // terminal that arrived a moment later read as a second thing opening.
    //
    // The pane is made to appear here the way the terminal makes one appear,
    // deliberately without the launcher's own `terminalVisible = true`: the
    // workbench must follow the session's state, not depend on another feature
    // poking its surface at the right moment.
    SessionDao(db).insert(session(title: 'Read the report'));
    await pump(tester);
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await tester.pumpAndSettle();
    expect(
      find.byType(TerminalPaneStack),
      findsNothing,
      reason: 'nothing of ours is running it yet',
    );

    final terminals = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    terminals.openTab(TerminalProfile.powerShell);
    final paneId = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .layout
        .panes
        .single;
    SessionDao(db).updatePaneId('s1', paneId);
    container.read(sessionsRevisionProvider.notifier).bump();
    // One frame, not a settle: the correction has to have happened before
    // anything was painted, or the conversation is still a surface the user saw
    // and then lost.
    await tester.pump();

    expect(container.read(terminalVisibleProvider), isTrue);
    expect(surfaces(tester).index, 0, reason: 'the terminal is the session');
    await tester.pumpAndSettle();
    expect(surfaces(tester).index, 0);
  });

  group('ending a session moves the user on', () {
    // The report: "when i end session why show this, why not switch to another
    // existing tab and show empty if no other tabs exist?" — the workbench sat
    // on the empty state of the session that had just been ended, with live
    // tabs behind it, because ending it took its pane away and left its row
    // selected.

    /// Right-clicks the [index]th tab and picks **End session** — the
    /// affordance the report was filed against, driven the way the user
    /// reaches it rather than by calling the controller.
    Future<void> endSessionOnTab(WidgetTester tester, int index) async {
      await tester.tap(
        find.byType(TerminalTabChip).at(index),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('End session'));
      await tester.pumpAndSettle();
    }

    final tombstone = find.textContaining(
      'No terminal of ours is running this session',
    );

    testWidgets('the tab that took its place is on screen, and says so', (
      tester,
    ) async {
      seedSessionInAPane(title: 'Refactor the parser');
      final terminals = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      terminals.openTab(TerminalProfile.powerShell);
      terminals.openTab(TerminalProfile.powerShell);
      container.read(selectedSessionIdProvider.notifier).select('s1');
      await pump(tester);
      expect(find.byType(TerminalTabChip), findsNWidgets(3));

      await endSessionOnTab(tester, 0);

      expect(tombstone, findsNothing);
      expect(find.byType(TerminalPaneStack), findsOneWidget);
      expect(find.byType(TerminalTabChip), findsNWidgets(2));
      expect(
        tester
            .widgetList<TerminalTabChip>(find.byType(TerminalTabChip))
            .where((chip) => chip.selected),
        hasLength(1),
        reason: 'the tab on screen is the one drawn as active',
      );
      expect(
        container.read(selectedSessionIdProvider),
        isNull,
        reason: 'the selection is released, not pointed somewhere else',
      );
    });

    testWidgets('ending the last one leaves the empty workbench', (
      tester,
    ) async {
      seedSessionInAPane(title: 'Refactor the parser');
      container.read(selectedSessionIdProvider.notifier).select('s1');
      await pump(tester);

      await endSessionOnTab(tester, 0);

      expect(tombstone, findsNothing);
      expect(find.byType(SessionTranscriptView), findsNothing);
      expect(
        find.byType(TerminalPaneStack),
        findsOneWidget,
        reason: 'with nothing selected the workbench is the terminal',
      );
      expect(container.read(selectedSessionIdProvider), isNull);
      // Empty, and left that way. The one automatic open belongs to opening the
      // app: a workbench that reopened a shell every time the last tab closed
      // would be one the user could never put down. The panes offer the button
      // instead — see `_NoTerminalOpen`.
      expect(find.byType(TerminalTabChip), findsNothing);
      expect(find.text('No terminal open'), findsOneWidget);
    });

    testWidgets('ending a session in another tab moves nothing', (
      tester,
    ) async {
      // Ending a session is "I am done with *this*". A background one is not
      // the thing the user is looking at, so their surface must stay put.
      final paneId = seedSessionInAPane(title: 'Refactor the parser');
      seedSessionInAPane(id: 's2', title: 'Audit the shell');
      container.read(selectedSessionIdProvider.notifier).select('s1');
      await pump(tester);

      await endSessionOnTab(tester, 1);

      expect(container.read(selectedSessionIdProvider), 's1');
      expect(
        container
            .read(terminalSessionsControllerProvider)
            .activeTab!
            .focusedPaneId,
        paneId,
      );
      expect(tombstone, findsNothing);
      expect(surfaces(tester).index, 0);
    });

    testWidgets('reading the conversation is left alone', (tester) async {
      // The empty state is what the user is being moved off, and it is not up
      // here. Releasing the selection on this surface would hand the reader
      // whichever session the neighbouring tab runs — the wrong transcript
      // rather than a tidier one.
      seedSessionInAPane(title: 'Refactor the parser');
      seedSessionInAPane(id: 's2', title: 'Audit the shell');
      container.read(selectedSessionIdProvider.notifier).select('s1');
      await pump(tester);
      await tester.tap(find.byTooltip('Chat view'));
      await tester.pumpAndSettle();

      await endSessionOnTab(tester, 0);

      expect(
        container.read(selectedSessionIdProvider),
        's1',
        reason: 'still the session whose conversation was open',
      );
      expect(surfaces(tester).index, 1);
    });
  });

  testWidgets('a session selected at mount never paints its chat first', (
    tester,
  ) async {
    // The flash the Loop 85 report predicted: the surface defaulted to the
    // conversation and a post-frame callback corrected it, so the frame the
    // user actually saw first was the wrong one.
    seedSessionInAPane();
    container.read(selectedSessionIdProvider.notifier).select('s1');

    await pumpOneFrame(tester);

    expect(surfaces(tester).index, 0, reason: 'the very first frame');
    await tester.pumpAndSettle();
    expect(surfaces(tester).index, 0);
  });

  testWidgets('a paneless session selected at mount paints no chat either', (
    tester,
  ) async {
    // The other half of the same guard. It used to be the case that stopped the
    // fix being "always show the terminal" — a paneless session had to reach
    // its conversation. It reaches the terminal's own empty state instead, and
    // never the chat surface, on the first frame or any after it.
    SessionDao(db).insert(session(title: 'Read the report'));
    container.read(selectedSessionIdProvider.notifier).select('s1');

    await pumpOneFrame(tester);

    expect(surfaces(tester).index, 0, reason: 'the very first frame');
    await tester.pumpAndSettle();
    expect(surfaces(tester).index, 0);
    expect(find.byType(TerminalPaneStack), findsNothing);
  });
}
