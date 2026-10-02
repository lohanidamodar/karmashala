import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:agent_cli/stream.dart' show ToolActivity;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_plan_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/sessions/presentation/tool_activity_row.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_ui/transcript.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../../support/tool_runs.dart';
import '../terminal/fake_instance.dart';

/// **An ACP session's conversation is the server's own rows** (ACP design,
/// C3 and C5): the view reads them down the server transcript path — the one
/// a PTY session's record comes down — with no file of its own to look for
/// and no CLI id to wait for. Tool rows, thinking and the plan all render.
void main() {
  /// What the server projects from `session_messages` for one session: a
  /// turn with thinking, a finished command, a failed one, a plan, and a call
  /// still running.
  final projected = <TranscriptMessage>[
    TranscriptMessage(role: 'user', text: 'List the files.', at: testTime),
    TranscriptMessage(
      role: 'agent',
      text: 'Looking at the directory.',
      thinking: 'A listing first, then decide.',
      at: testTime,
    ),
    TranscriptMessage(
      role: 'tool',
      text: '',
      tool: const ToolActivity(
        name: 'Bash',
        subject: 'ls -la',
        output: 'total 3',
      ),
      at: testTime,
    ),
    TranscriptMessage(
      role: 'tool',
      text: '',
      tool: const ToolActivity(
        name: 'Bash',
        subject: 'rm -rf /nope',
        output: 'permission denied',
        isError: true,
      ),
      at: testTime,
    ),
    TranscriptMessage(
      role: 'tool',
      text: '',
      tool: const ToolActivity(
        name: 'plan',
        subject: '2 steps',
        plan: AgentPlan(
          items: [
            AgentPlanItem(
              text: 'Read the code',
              state: AgentPlanItemState.completed,
            ),
            AgentPlanItem(text: 'Fix it', state: AgentPlanItemState.inProgress),
          ],
        ),
      ),
      at: testTime,
    ),
    TranscriptMessage(
      role: 'tool',
      text: '',
      tool: const ToolActivity(name: 'Read', subject: 'lib/main.dart'),
      pendingToolUseId: 'call-9',
      at: testTime,
    ),
  ];

  late ProviderContainer container;

  setUp(() async {
    final db = TestMachine();
    final server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(
        agentId: AgentIds.claudeAcp,
        path: r'C:\Users\me\.bin\claude-agent-acp.exe',
      ),
    );
    // No CLI id, no pane: the server's rows are all there is, and enough.
    db.server.sessionRows.insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Over ACP',
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: testTime,
      ),
    );
    container = ProviderContainer(
      overrides: [
        await server.override(),
        ...fakeTerminalOverrides(machine: db),
        // The server path's provider, answered as `sessions.transcript` would.
        sessionChatTranscriptProvider.overrideWith(
          (ref, id) => Stream.value(projected),
        ),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        sessionDeliveryProvider.overrideWith(
          (ref, _) async => SessionDelivery.unknown,
        ),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => Stream.value(
            AgentStatusReport(
              agentId: AgentIds.claudeAcp,
              sessionId: id,
              status: AgentActivityStatus.idle,
              observedAt: testTime,
              source: AgentStatusSource.protocol,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  Future<void> pump(WidgetTester tester) async {
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

  testWidgets('the projected page renders: words, thinking, tool rows', (
    tester,
  ) async {
    await pump(tester);

    // A chat, not the "no chat view" fallback the store-less adapter used to earn.
    expect(find.textContaining('No chat view'), findsNothing);
    expect(find.textContaining('Looking at the directory.'), findsOneWidget);
    expect(find.byType(ThinkingAccordion), findsOneWidget);
    expect(find.text('Thought'), findsOneWidget);
    // The composer is live, as for a running PTY session: sends and Stop go
    // to the server as for any chat.
    expect(find.text('Message the agent…'), findsOneWidget);

    await openToolRuns(tester);
    await tester.pumpAndSettle();
    expect(find.text('BASH'), findsWidgets);
    expect(
      find.descendant(
        of: find.byType(ToolActivityBody),
        matching: find.text('ls -la'),
      ),
      findsOneWidget,
    );
    expect(find.text('Failed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the plan is read off the same rows, with no plan tool to know', (
    tester,
  ) async {
    await pump(tester);

    final reading = container.read(sessionAgentPlanProvider('s1'));
    expect(reading.hasPlan, isTrue, reason: reading.toString());
    expect(reading.plan!.items.map((item) => item.text), [
      'Read the code',
      'Fix it',
    ]);
    expect(reading.plan!.current?.text, 'Fix it');
  });
}
