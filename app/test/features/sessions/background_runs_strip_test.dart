import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/stream.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/cli_detection/application/subagent_providers.dart';
import 'package:karmashala/src/features/cli_detection/presentation/subagent_turns_tile.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/background_runs_strip.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// **Every background run the session is waiting on, listed in its chat**:
/// two agents a Claude Code session launched with `run_in_background`, and a
/// command, after the turn that started them ended.
void main() {
  final issued = DateTime.utc(2026, 10, 5, 6);

  TranscriptMessage launch(
    String id,
    String description,
    BackgroundRunState state, {
    BackgroundRunKind kind = BackgroundRunKind.agent,
    DateTime? at,
    DateTime? endedAt,
    SubagentRef? subagent,
  }) => TranscriptMessage(
    role: 'tool',
    text: kind == BackgroundRunKind.agent
        ? 'Agent($description)'
        : 'Bash($description)',
    tool: ToolActivity(
      name: kind == BackgroundRunKind.agent ? 'Agent' : 'Bash',
      subject: description,
      output: 'launched',
    ),
    at: at ?? issued,
    subagent: subagent,
    background: BackgroundRun(
      id: id,
      kind: kind,
      state: state,
      description: description,
      endedAt: endedAt,
    ),
  );

  Future<void> pump(
    WidgetTester tester,
    List<TranscriptMessage> messages, {
    DateTime? now,
  }) async {
    final db = TestMachine();
    final server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server
      ..projectRows.insert(project())
      ..repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
    server.sessionRows.insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'achiver',
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: testTime,
        surface: SessionSurface.pane,
        externalSessionId: 'ext-1',
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          await server.override(),
          clockProvider.overrideWithValue(
            FixedClock(now ?? issued.add(const Duration(minutes: 5))),
          ),
          // The turn that launched them is over: the session waits on them.
          agentSessionStatusProvider.overrideWith(
            (ref, id) => Stream.value(
              AgentStatusReport(
                agentId: AgentIds.claudeCode,
                sessionId: id,
                status: AgentActivityStatus.idle,
                observedAt: issued,
                source: AgentStatusSource.stateFile,
              ),
            ),
          ),
          sessionChatTranscriptProvider.overrideWith(
            (ref, id) => Stream.value(messages),
          ),
          subagentTurnsProvider.overrideWith(
            (ref, key) async => const <TranscriptMessage>[],
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [BackgroundRunsStrip(sessionId: 's1')],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('two background agents are listed after the turn ended, each '
      'with how long it has run', (tester) async {
    await pump(tester, [
      launch(
        'a1',
        'Strip idle detection',
        BackgroundRunState.running,
        at: issued.subtract(const Duration(seconds: 19)),
      ),
      launch(
        'a2',
        'Unify tasks and work items',
        BackgroundRunState.running,
        at: issued.add(const Duration(minutes: 4, seconds: 38)),
      ),
    ]);

    expect(find.text('Strip idle detection'), findsOneWidget);
    expect(find.text('Unify tasks and work items'), findsOneWidget);
    expect(find.textContaining('5m 19s'), findsOneWidget);
    expect(find.textContaining('22s'), findsOneWidget);
    expect(find.text('2 background agents running'), findsOneWidget);
  });

  testWidgets('one that finished stays listed as done while the other runs; '
      'one that ended before them is not', (tester) async {
    await pump(tester, [
      launch(
        'a0',
        'An older job',
        BackgroundRunState.completed,
        at: issued.subtract(const Duration(hours: 1)),
        endedAt: issued.subtract(const Duration(minutes: 50)),
      ),
      launch(
        'a1',
        'Strip idle detection',
        BackgroundRunState.completed,
        endedAt: issued.add(const Duration(minutes: 2)),
      ),
      launch(
        'b1',
        'Run the app tests',
        BackgroundRunState.running,
        kind: BackgroundRunKind.command,
        at: issued.add(const Duration(seconds: 30)),
      ),
    ]);

    expect(find.text('An older job'), findsNothing);
    expect(find.text('Strip idle detection'), findsOneWidget);
    expect(find.textContaining('done'), findsOneWidget);
    expect(find.text('Run the app tests'), findsOneWidget);
    expect(find.text('1 background command running'), findsOneWidget);
  });

  testWidgets('with nothing running there is nothing to show', (tester) async {
    await pump(tester, [
      launch(
        'a1',
        'Strip idle detection',
        BackgroundRunState.completed,
        endedAt: issued.add(const Duration(minutes: 2)),
      ),
    ]);

    expect(find.text('Strip idle detection'), findsNothing);
    expect(tester.getSize(find.byType(BackgroundRunsStrip)), Size.zero);
  });

  testWidgets('an agent opens to its own turns', (tester) async {
    await pump(tester, [
      launch(
        'a1',
        'Strip idle detection',
        BackgroundRunState.running,
        subagent: const SubagentRef(
          toolUseId: 'toolu_1',
          filePath: r'C:\store\s1\subagents\agent-a1.jsonl',
          agentType: 'general-purpose',
          description: 'Strip idle detection',
          spawnDepth: 1,
        ),
      ),
    ]);

    await tester.tap(find.text('Strip idle detection'));
    await tester.pumpAndSettle();

    expect(find.byType(SubagentTurnsTile), findsOneWidget);
  });
}
