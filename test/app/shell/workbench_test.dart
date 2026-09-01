import 'package:chitragupta/src/app/shell/workbench.dart';
import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/agents/domain/agent_ids.dart';
import 'package:chitragupta/src/features/agents/domain/agent_registry.dart';
import 'package:chitragupta/src/features/agents/domain/agent_status.dart';
import 'package:chitragupta/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:chitragupta/src/features/git/application/changes_providers.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/sessions/application/delivery_providers.dart';
import 'package:chitragupta/src/features/sessions/application/session_handoff_service.dart';
import 'package:chitragupta/src/features/sessions/application/session_providers.dart';
import 'package:chitragupta/src/features/sessions/application/session_status_providers.dart';
import 'package:chitragupta/src/features/sessions/application/session_ui_providers.dart';
import 'package:chitragupta/src/features/sessions/data/session_dao.dart';
import 'package:chitragupta/src/features/sessions/domain/session_delivery.dart';
import 'package:chitragupta/src/features/sessions/domain/session_fork.dart';
import 'package:chitragupta/src/features/sessions/presentation/approval_request_card.dart';
import 'package:chitragupta/src/features/sessions/presentation/delivery_strip.dart';
import 'package:chitragupta/src/features/sessions/presentation/permission_mode_chip.dart';
import 'package:chitragupta/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:chitragupta/src/core/process/command_runner_providers.dart';
import 'package:chitragupta/src/features/terminal/application/system_terminal_providers.dart';
import 'package:chitragupta/src/features/terminal/data/system_terminal_service.dart';
import 'package:chitragupta/src/features/terminal/domain/terminal_profile.dart';
import 'package:chitragupta/src/features/terminal/presentation/terminal_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';

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
        sessionTranscriptProvider.overrideWith((ref) => Stream.value(const [])),
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

  Future<void> pump(WidgetTester tester) async {
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
    seedSessionInAPane();
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await pump(tester);

    IndexedStack surfaces() =>
        tester.widget<IndexedStack>(find.byKey(kWorkbenchSurfaces));

    expect(surfaces().children.length, 2, reason: 'both surfaces stay alive');
    expect(surfaces().index, 0, reason: 'the terminal is showing');

    await tester.tap(find.byTooltip('Chat view'));
    await tester.pumpAndSettle();
    expect(surfaces().index, 1, reason: 'now the conversation is');
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

  testWidgets('the delivery row is one row of chrome, not chips on the pane', (
    tester,
  ) async {
    // The report: the actions were drawn straight onto the terminal's own
    // background, under a rule of their own, at the size a chip is in a
    // message column. They are the bar's now — and the state line shares the
    // row with them rather than reserving one above it.
    delivery = const SessionDelivery(
      branch: 'work',
      baseBranch: 'origin/main',
      hasRemote: true,
      dirtyFiles: 2,
      hasWorktree: true,
    );
    continuation = possible;
    seedSessionInAPane();
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await pump(tester);

    expect(tester.widget<DeliveryStrip>(hostedStrip).hostedOnTerminal, isTrue);
    expectBelowTheTerminal(tester, find.text('Commit'));
    // Where the work stands and what to do about it are on the same line —
    // one Wrap holds both, so the bar spends a second row only when it has run
    // out of width, never on a state line that is usually four words.
    final line = tester.getCenter(find.text('Working')).dy;
    expect(
      tester.getCenter(find.text('work')).dy,
      moreOrLessEquals(line, epsilon: 1),
    );
    expect(
      tester.getCenter(find.text('Commit')).dy,
      moreOrLessEquals(line, epsilon: 1),
    );
  });

  testWidgets('the bar survives the minimum window and larger text', (
    tester,
  ) async {
    // Everything the bar can hold at once: a permission mode, a stage, a
    // branch, five actions and the toggle. It wraps rather than clipping, and
    // every control in it still has a name for Narrator to read.
    delivery = const SessionDelivery(
      branch: 'session/fix-the-login',
      baseBranch: 'origin/main',
      hasRemote: true,
      dirtyFiles: 2,
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
      because: 'the bar is the busiest row of chrome in the window',
    );
  });

  testWidgets('an agent blocked on a prompt is answerable from the terminal', (
    tester,
  ) async {
    agentStatus = AgentActivityStatus.awaitingApproval;
    agentEvidence = const ['Do you want to make this edit to main.dart?'];
    agentWaiting = AgentWaitKind.approval;
    seedSessionInAPane();
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await pump(tester);

    expect(find.byType(ApprovalRequestCard), findsOneWidget);
    expect(find.textContaining('is waiting for you'), findsOneWidget);
    // The agent's own words, and the buttons its descriptor names.
    expect(
      find.textContaining('Do you want to make this edit'),
      findsOneWidget,
    );
    expect(find.byType(FilledButton), findsWidgets);
    // The card's "Terminal view" button is the one thing that makes no sense
    // here: it is hosted *on* the terminal.
    expect(find.widgetWithText(TextButton, 'Terminal view'), findsNothing);
  });

  testWidgets('the approval card takes no height until there is an approval', (
    tester,
  ) async {
    // The rule for everything in the dock: it must not reserve terminal rows
    // for something it might one day have to say.
    seedSessionInAPane();
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await pump(tester);

    expect(tester.getSize(find.byType(ApprovalRequestCard)).height, 0);
  });

  testWidgets('an agent that merely messaged is offered no keys', (
    tester,
  ) async {
    // The live complaint: a finished turn nudged the user, and the dock offered
    // Approve — a button that types Enter into a prompt with nothing open.
    agentStatus = AgentActivityStatus.awaitingApproval;
    agentEvidence = const ['Claude is waiting for your input'];
    agentWaiting = AgentWaitKind.input;
    seedSessionInAPane();
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await pump(tester);

    // The headline, not the quoted message: both say it, and only one of them
    // is the app speaking.
    expect(
      find.textContaining('Claude Code is waiting for your input'),
      findsOneWidget,
    );
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
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

  testWidgets('the selected session losing its pane stays on the terminal', (
    tester,
  ) async {
    // The workbench never moves the user to the conversation by itself, not
    // even here. The pane going away changes what the terminal surface *says*,
    // not which surface is up.
    seedSessionInAPane();
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await pump(tester);
    expect(surfaces(tester).index, 0);

    container
        .read(terminalSessionsControllerProvider.notifier)
        .closeTab(
          container.read(terminalSessionsControllerProvider).tabs.single.id,
          detach: false,
        );
    await tester.pumpAndSettle();

    expect(surfaces(tester).index, 0);
    expect(
      find.textContaining('No terminal of ours is running this session'),
      findsOneWidget,
    );
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
