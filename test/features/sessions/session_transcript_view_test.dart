import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/agents/domain/agent_ids.dart';
import 'package:chitragupta/src/features/agents/domain/agent_status.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/sessions/application/delivery_providers.dart';
import 'package:chitragupta/src/features/sessions/application/session_status_providers.dart';
import 'package:chitragupta/src/features/sessions/data/session_dao.dart';
import 'package:chitragupta/src/features/sessions/domain/session.dart';
import 'package:chitragupta/src/features/sessions/domain/session_delivery.dart';
import 'package:chitragupta/src/features/sessions/domain/session_launch.dart';
import 'package:chitragupta/src/features/sessions/domain/session_status.dart';
import 'package:chitragupta/src/features/terminal/application/system_terminal_providers.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:chitragupta/src/features/terminal/data/system_terminal_service.dart';
import 'package:chitragupta/src/features/terminal/domain/terminal_profile.dart';
import 'package:chitragupta/src/features/sessions/application/session_ui_providers.dart';
import 'package:chitragupta/src/features/sessions/domain/session_event.dart';
import 'package:chitragupta/src/features/sessions/domain/session_event_types.dart';
import 'package:chitragupta/src/features/sessions/presentation/markdown_message.dart';
import 'package:chitragupta/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

void main() {
  testWidgets('renders user and agent messages from the transcript', (
    tester,
  ) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);

    final events = [
      SessionEvent(
        id: 1,
        sessionId: 's1',
        seq: 0,
        type: SessionEventTypes.userMessage,
        payload: '{"text":"hello"}',
        createdAt: testTime,
      ),
      SessionEvent(
        id: 2,
        sessionId: 's1',
        seq: 1,
        type: SessionEventTypes.agentMessage,
        payload: '{"text":"Echo: hello"}',
        createdAt: testTime,
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sessionTranscriptProvider.overrideWith((ref) => Stream.value(events)),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SessionTranscriptView(sessionId: 's1')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Message bodies render as (selectable) Markdown, CLI-style.
    expect(find.byType(MarkdownMessage), findsNWidgets(2));
    expect(find.textContaining('Echo: hello'), findsOneWidget);
    // Role eyebrows are uppercased.
    expect(find.text('YOU'), findsOneWidget);
    expect(find.text('AGENT'), findsOneWidget);
    // The input is always usable; when idle it invites continuing the session.
    expect(find.text('Type to continue this session…'), findsOneWidget);
  });

  /// A session run by an agent whose conversation we cannot read (Antigravity
  /// has an adapter and no readable store), optionally in a pane of ours.
  ///
  /// This is the pair the Loop 85 fallback created: the workbench sends a
  /// session with no terminal *here*, so what this view says about the terminal
  /// has to be true of the session in front of it.
  Future<void> pumpNoChatAgent(
    WidgetTester tester, {
    required bool inAPane,
  }) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(
      db,
    ).insert(agentInstallation(agentId: AgentIds.antigravity));
    final dao = SessionDao(db)
      ..insert(
        Session(
          id: 's1',
          repositoryId: 'r1',
          agentInstallationId: 'a1',
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
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        sessionDeliveryProvider.overrideWith(
          (ref, _) async => SessionDelivery.unknown,
        ),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => Stream.value(
            AgentStatusReport(
              agentId: AgentIds.antigravity,
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

    if (inAPane) {
      final terminals = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      terminals.openTab(TerminalProfile.powerShell);
      dao.updatePaneId(
        's1',
        container
            .read(terminalSessionsControllerProvider)
            .activeTab!
            .layout
            .panes
            .single,
      );
    }

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: SessionTranscriptView(sessionId: 's1')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('an agent with no chat view points at its terminal', (
    tester,
  ) async {
    await pumpNoChatAgent(tester, inAPane: true);

    expect(find.textContaining('Its terminal is the session'), findsOneWidget);
  });

  testWidgets('...but not when there is no terminal left to point at', (
    tester,
  ) async {
    // The two fallbacks used to fight: the workbench lands a session with no
    // pane here *because* it has no terminal, and this view answered "its
    // terminal is the session" — sending the user to a surface that is not
    // there.
    await pumpNoChatAgent(tester, inAPane: false);

    expect(find.textContaining('Its terminal is the session'), findsNothing);
    expect(find.textContaining('no terminal open'), findsOneWidget);
    expect(find.textContaining('Type below to run it again'), findsOneWidget);
  });
}
