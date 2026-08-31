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
  IndexedStack surfaces(WidgetTester tester) => tester.widget<IndexedStack>(
    find.ancestor(
      of: find.byType(TerminalPaneStack, skipOffstage: false),
      matching: find.byType(IndexedStack),
    ),
  );

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

  testWidgets('a selected session gets a tab beside the terminal tabs', (
    tester,
  ) async {
    seedSessionInAPane(title: 'Refactor the parser');
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await pump(tester);

    expect(find.text('Refactor the parser'), findsOneWidget);
    expect(find.text('PowerShell'), findsOneWidget);
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

  testWidgets('a session with no pane of ours lands on its conversation', (
    tester,
  ) async {
    // An imported session resumed elsewhere, a session opened in an external
    // terminal, or one whose pane has been ended: there is no terminal to
    // switch to, so the fallback is the surface that does have something.
    SessionDao(db).insert(session(title: 'Read the report'));
    await pump(tester);
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await tester.pumpAndSettle();

    expect(container.read(terminalVisibleProvider), isFalse);
    expect(find.byType(SessionTranscriptView), findsOneWidget);
    // Nothing to toggle to, so no toggle is offered.
    expect(find.byTooltip('Terminal view'), findsNothing);
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
    expect(container.read(terminalVisibleProvider), isFalse);
    expect(find.byType(SessionTranscriptView), findsOneWidget);
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

    await tester.tap(find.byTooltip('Chat view'));
    await tester.pumpAndSettle();

    expect(container.read(terminalVisibleProvider), isFalse);
    expect(find.byType(SessionTranscriptView), findsOneWidget);

    await tester.tap(find.byTooltip('Terminal view'));
    await tester.pumpAndSettle();
    expect(container.read(terminalVisibleProvider), isTrue);
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

    IndexedStack surfaces() => tester.widget<IndexedStack>(
      find.ancestor(
        of: find.byType(TerminalPaneStack, skipOffstage: false),
        matching: find.byType(IndexedStack),
      ),
    );

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

  testWidgets('an agent pane carries its permission chip on the strip', (
    tester,
  ) async {
    // No selection: this is the terminal view on its own, which is where the
    // chip did not exist. The mode was readable only from the chat composer,
    // so the one control the user needs before letting an agent run was
    // invisible on the surface they were watching it on.
    seedSessionInAPane();
    await pump(tester);

    expect(find.byType(PermissionModeChip), findsOneWidget);

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

  testWidgets('an agent blocked on a prompt is answerable from the terminal', (
    tester,
  ) async {
    agentStatus = AgentActivityStatus.awaitingApproval;
    agentEvidence = const ['Do you want to make this edit to main.dart?'];
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
      find.byType(SessionTranscriptView),
      findsOneWidget,
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

  testWidgets('the selected session losing its pane returns it to chat', (
    tester,
  ) async {
    // The same rule read the other way: the surface follows the session, so a
    // pane ended under it leaves the conversation as the only thing it has.
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

    expect(surfaces(tester).index, 1);
    expect(find.byTooltip('Terminal view'), findsNothing);
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

  testWidgets('a paneless session selected at mount paints chat first', (
    tester,
  ) async {
    // The other half of the same guard, and what stops the fix being "always
    // show the terminal": a session with nothing of ours running it must not
    // flash a terminal it does not own on the way to its conversation.
    SessionDao(db).insert(session(title: 'Read the report'));
    container.read(selectedSessionIdProvider.notifier).select('s1');

    await pumpOneFrame(tester);

    expect(surfaces(tester).index, 1, reason: 'the very first frame');
    await tester.pumpAndSettle();
    expect(surfaces(tester).index, 1);
  });
}
