import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/agents/application/agent_providers.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/agents/domain/agent_ids.dart';
import 'package:chitragupta/src/features/agents/domain/agent_registry.dart';
import 'package:chitragupta/src/features/agents/domain/agent_status.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/sessions/application/session_status_providers.dart';
import 'package:chitragupta/src/features/sessions/data/session_dao.dart';
import 'package:chitragupta/src/features/sessions/domain/session.dart';
import 'package:chitragupta/src/features/sessions/domain/session_launch.dart';
import 'package:chitragupta/src/features/sessions/domain/session_status.dart';
import 'package:chitragupta/src/features/sessions/presentation/approval_request_card.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:chitragupta/src/features/terminal/domain/agent_pane_launch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// A session row and a scope whose status provider yields exactly [report].
///
/// The real provider polls on a timer, which would outlive the widget tree and
/// trip flutter_test's pending-timer check; the card only cares what the report
/// says.
///
/// [live] opens a (process-free) pane and points the row at it, which is what
/// decides whether the card can offer to type anything at all.
({AppDatabase db, Widget app, ProviderContainer container}) harness({
  required String agentId,
  required AgentStatusReport report,
  bool live = true,
  bool hostedOnTerminal = false,
}) {
  final db = AppDatabase.memory();
  ExecutionEnvironmentDao(db).upsert(windowsEnv());
  ProjectDao(db).insert(project());
  RepositoryDao(db).insert(repository());
  AgentInstallationDao(db).insert(agentInstallation(agentId: agentId));
  final dao = SessionDao(db)
    ..insert(
      Session(
        id: 's1',
        repositoryId: repository().id,
        agentInstallationId: agentInstallation(agentId: agentId).id,
        title: 'Session',
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: testTime,
        surface: SessionSurface.pane,
      ),
    );

  final container = ProviderContainer(
    overrides: [
      ...fakeTerminalOverrides(database: db),
      agentRegistryProvider.overrideWithValue(AgentRegistry.builtIn),
      agentSessionStatusProvider.overrideWith(
        (ref, id) => Stream.value(report),
      ),
    ],
  );
  if (live) {
    final opened = container
        .read(terminalSessionsControllerProvider.notifier)
        .openAgentTab(
          AgentPaneLaunch(
            agentId: agentId,
            executable: agentId,
            sessionId: 's1',
            title: 'Session',
          ),
        );
    dao.updatePaneId('s1', opened.paneId);
  }
  return (
    db: db,
    container: container,
    app: UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: ApprovalRequestCard(
            sessionId: 's1',
            hostedOnTerminal: hostedOnTerminal,
          ),
        ),
      ),
    ),
  );
}

AgentStatusReport report({
  required String agentId,
  AgentActivityStatus status = AgentActivityStatus.awaitingApproval,
  AgentStatusSource source = AgentStatusSource.terminalGrid,
  List<String> evidence = const [],
  // Most of these cases are about an open prompt, which is the only kind the
  // card may answer. The other two kinds have their own tests below.
  AgentWaitKind waiting = AgentWaitKind.approval,
}) => AgentStatusReport(
  agentId: agentId,
  sessionId: 's1',
  status: status,
  source: source,
  observedAt: testTime,
  evidence: evidence,
  waiting: waiting,
);

void main() {
  testWidgets('nothing is drawn unless an approval is pending', (tester) async {
    final h = harness(
      agentId: AgentIds.claudeCode,
      report: report(
        agentId: AgentIds.claudeCode,
        status: AgentActivityStatus.working,
      ),
    );
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    await tester.pumpWidget(h.app);
    // The status provider is a stream: its first frame is AsyncLoading, and the
    // card draws nothing until a report actually arrives.
    await tester.pumpAndSettle();

    expect(find.byType(Card), findsNothing);
    expect(find.textContaining('waiting for you'), findsNothing);
  });

  testWidgets('quotes the agent screen verbatim, without interpreting it', (
    tester,
  ) async {
    final h = harness(
      agentId: AgentIds.claudeCode,
      report: report(
        agentId: AgentIds.claudeCode,
        evidence: const ['Claude wants to run:', '  rm -rf build/'],
      ),
    );
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    await tester.pumpWidget(h.app);
    // The status provider is a stream: its first frame is AsyncLoading, and the
    // card draws nothing until a report actually arrives.
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Claude Code is waiting for you'),
      findsOneWidget,
    );
    expect(find.text('From its terminal:'), findsOneWidget);
    // The rows exactly as the agent drew them. Nothing here summarises an
    // action the user is about to authorise.
    expect(find.text('Claude wants to run:\n  rm -rf build/'), findsOneWidget);
  });

  testWidgets('says it does not know when the source carried nothing', (
    tester,
  ) async {
    final h = harness(
      agentId: AgentIds.claudeCode,
      report: report(
        agentId: AgentIds.claudeCode,
        source: AgentStatusSource.hook,
      ),
    );
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    await tester.pumpWidget(h.app);
    // The status provider is a stream: its first frame is AsyncLoading, and the
    // card draws nothing until a report actually arrives.
    await tester.pumpAndSettle();

    // The honest empty state. Inventing a description of what is being approved
    // would be the worst thing this widget could do.
    expect(find.textContaining('but not what'), findsOneWidget);
    expect(find.textContaining('Open the terminal view'), findsOneWidget);
  });

  testWidgets('offers both answers for Claude Code, and names the keys', (
    tester,
  ) async {
    final h = harness(
      agentId: AgentIds.claudeCode,
      report: report(
        agentId: AgentIds.claudeCode,
        evidence: const ['Proceed?'],
      ),
    );
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    await tester.pumpWidget(h.app);
    // The status provider is a stream: its first frame is AsyncLoading, and the
    // card draws nothing until a report actually arrives.
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Approve'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Deny'), findsOneWidget);
    // The user is authorising a keystroke, so the card says which one — Enter
    // confirms whatever Claude has highlighted, not a fixed "yes".
    expect(find.textContaining('highlighted'), findsOneWidget);
    expect(find.textContaining('Sends Esc'), findsOneWidget);
  });

  testWidgets('offers no Deny for Codex, and says why', (tester) async {
    final h = harness(
      agentId: AgentIds.codex,
      report: report(
        agentId: AgentIds.codex,
        evidence: const ['Press enter to continue'],
      ),
    );
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    await tester.pumpWidget(h.app);
    // The status provider is a stream: its first frame is AsyncLoading, and the
    // card draws nothing until a report actually arrives.
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Continue'), findsOneWidget);
    expect(find.byType(OutlinedButton), findsNothing);
    // Esc is a guess at another program's bindings; the card points at the
    // terminal instead of pressing it.
    expect(find.textContaining('names no way to decline'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Terminal view'), findsOneWidget);
  });

  testWidgets('a session with no live pane cannot be answered here', (
    tester,
  ) async {
    final h = harness(
      agentId: AgentIds.claudeCode,
      report: report(
        agentId: AgentIds.claudeCode,
        evidence: const ['Proceed?'],
      ),
      // An external terminal, or a session whose process has gone: there is
      // nothing to type into. Buttons that silently did nothing would be worse
      // than none.
      live: false,
    );
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    await tester.pumpWidget(h.app);
    // The status provider is a stream: its first frame is AsyncLoading, and the
    // card draws nothing until a report actually arrives.
    await tester.pumpAndSettle();

    expect(find.textContaining('no live terminal here'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });

  group('a session with no prompt open is never offered a key', () {
    // The live misclassification, reproduced end to end. Claude Code finished a
    // turn, posted a message and nudged; the card announced an approval and
    // offered Approve, which sends Enter — and at an idle prompt Enter submits
    // whatever is in the composer.
    testWidgets('an idle nudge says so and offers nothing to press', (
      tester,
    ) async {
      final h = harness(
        agentId: AgentIds.claudeCode,
        report: report(
          agentId: AgentIds.claudeCode,
          source: AgentStatusSource.hook,
          evidence: const ['Claude is waiting for your input'],
          waiting: AgentWaitKind.input,
        ),
      );
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      await tester.pumpWidget(h.app);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Claude Code is waiting for your input'),
        findsOneWidget,
      );
      expect(find.text('Claude is waiting for your input'), findsOneWidget);
      expect(find.textContaining('nothing to approve'), findsOneWidget);
      // The whole point: no key is offered into a session with no prompt open.
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.text('Approve'), findsNothing);
      expect(find.text('Deny'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Terminal view'), findsOneWidget);
    });

    testWidgets('an unrecognised notice refuses to guess an approval', (
      tester,
    ) async {
      final h = harness(
        agentId: AgentIds.claudeCode,
        report: report(
          agentId: AgentIds.claudeCode,
          source: AgentStatusSource.hook,
          evidence: const ['Something we have never seen'],
          waiting: AgentWaitKind.unrecorded,
        ),
      );
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      await tester.pumpWidget(h.app);
      await tester.pumpAndSettle();

      expect(find.textContaining('needs your attention'), findsOneWidget);
      expect(find.textContaining('cannot tell'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
    });

    testWidgets('Codex keeps its Continue button when a prompt is open', (
      tester,
    ) async {
      // The asymmetry survives the split: Codex names Enter and names no way to
      // decline, and that is a different question from whether a prompt is open.
      final h = harness(
        agentId: AgentIds.codex,
        report: report(
          agentId: AgentIds.codex,
          evidence: const ['Press enter to continue'],
        ),
      );
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      await tester.pumpWidget(h.app);
      await tester.pumpAndSettle();

      expect(find.widgetWithText(FilledButton, 'Continue'), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNothing);
    });
  });

  testWidgets('hosted on the terminal, it stops pointing at the terminal', (
    tester,
  ) async {
    // Loop 85 hosts this same card under the terminal as well as in the
    // conversation. Everything it can only say from the conversation — "open
    // the terminal view", and the button that does it — would send the user to
    // where they already are.
    final h = harness(
      agentId: AgentIds.codex,
      report: report(agentId: AgentIds.codex),
      hostedOnTerminal: true,
    );
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    await tester.pumpWidget(h.app);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextButton, 'Terminal view'), findsNothing);
    expect(
      find.textContaining('Read the prompt in the terminal above'),
      findsOneWidget,
    );
    // Codex names no way to decline, and the refusal route is the terminal it
    // is already sitting under.
    expect(find.textContaining('type into the terminal above'), findsOneWidget);
    // What it does offer is unchanged: the answer the agent itself named.
    expect(find.widgetWithText(FilledButton, 'Continue'), findsOneWidget);
  });
}
