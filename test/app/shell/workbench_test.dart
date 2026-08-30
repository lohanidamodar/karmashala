import 'package:chitragupta/src/app/shell/workbench.dart';
import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/agents/domain/agent_ids.dart';
import 'package:chitragupta/src/features/agents/domain/agent_status.dart';
import 'package:chitragupta/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/sessions/application/session_status_providers.dart';
import 'package:chitragupta/src/features/sessions/application/session_ui_providers.dart';
import 'package:chitragupta/src/features/sessions/data/session_dao.dart';
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

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
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
        agentSessionStatusProvider.overrideWith(
          (ref, id) => Stream.value(
            AgentStatusReport(
              agentId: AgentIds.claudeCode,
              sessionId: id,
              status: AgentActivityStatus.idle,
              observedAt: testTime,
              source: AgentStatusSource.none,
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

  /// A session running in a pane of ours — the only kind that has two views.
  String seedSessionInAPane() {
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
    dao.insert(session(title: 'Refactor the parser'));
    dao.updatePaneId('s1', paneId);
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
    seedSessionInAPane();
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await pump(tester);

    expect(find.text('Refactor the parser'), findsOneWidget);
    expect(find.text('PowerShell'), findsOneWidget);
  });

  testWidgets('the view toggle swaps the two renderings of one session', (
    tester,
  ) async {
    final paneId = seedSessionInAPane();
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await pump(tester);

    // Selecting a session lands on its conversation.
    expect(container.read(terminalVisibleProvider), isFalse);
    expect(find.byTooltip('Terminal view'), findsOneWidget);

    await tester.tap(find.byTooltip('Terminal view'));
    await tester.pumpAndSettle();

    expect(container.read(terminalVisibleProvider), isTrue);
    // The switch is a rendering change, not a lifecycle one: the pane it named
    // is still the same live instance.
    final instance = container
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(paneId);
    expect(instance, isNotNull);
    expect((instance! as FakeTerminalInstance).disposed, isFalse);

    await tester.tap(find.byTooltip('Chat view'));
    await tester.pumpAndSettle();
    expect(container.read(terminalVisibleProvider), isFalse);
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
    expect(surfaces().index, 1, reason: 'the conversation is showing');

    await tester.tap(find.byTooltip('Terminal view'));
    await tester.pumpAndSettle();
    expect(surfaces().index, 0, reason: 'now the terminal is');
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
}
