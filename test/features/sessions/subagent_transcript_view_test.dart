import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/subagent_providers.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/cli_detection/presentation/subagent_turns_tile.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/launch.dart';
import 'package:agent_cli/stream.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
import '../terminal/fake_instance.dart';

/// A subagent shown where it belongs: under the `Task` call that spawned it.
///
/// The claim under test is cost as much as it is rendering. A fan-out of ten
/// delegates must not bury the parent conversation, so the rows are collapsed;
/// and one real session on this machine has 1,485 MiB of subagent transcripts
/// behind a 115 MB parent, so **a row that is not expanded is not read**. That
/// last one is counted, not timed.
void main() {
  /// The `Task` call, the delegate behind it, and a plain turn either side.
  SubagentRef reference({
    String toolUseId = 'toolu_01',
    String description = 'survey the readers',
    String agentType = 'Explore',
    int spawnDepth = 1,
  }) => SubagentRef(
    toolUseId: toolUseId,
    // One file per delegate, keyed off the id — two refs that shared a path
    // would be the same subagent, and `SubagentRef` says so.
    filePath: '/store/s1/subagents/agent-$toolUseId.jsonl',
    agentType: agentType,
    description: description,
    spawnDepth: spawnDepth,
  );

  List<TranscriptMessage> transcript({SubagentRef? subagent}) => [
    const TranscriptMessage(role: 'user', text: 'delegate the survey'),
    TranscriptMessage(
      role: 'tool',
      text: 'Task(survey the readers)',
      tool: const ToolActivity(name: 'Task', subject: 'survey the readers'),
      subagent: subagent,
    ),
    const TranscriptMessage(role: 'agent', text: 'the survey came back'),
  ];

  final delegateTurns = [
    const TranscriptMessage(role: 'user', text: 'survey the readers'),
    const TranscriptMessage(
      role: 'tool',
      text: 'Grep(readCliTranscript)',
      tool: ToolActivity(name: 'Grep', subject: 'readCliTranscript'),
    ),
    const TranscriptMessage(
      role: 'agent',
      text: 'only one reader opens a path',
    ),
  ];

  /// Counts every subagent transcript read, by path.
  final reads = <String>[];

  Widget build({
    required List<TranscriptMessage> messages,
    Map<String, List<TranscriptMessage>> turns = const {},
  }) {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(
      db,
    ).insert(agentInstallation(agentId: AgentIds.claudeCode));
    SessionDao(db).insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Session',
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: testTime,
        surface: SessionSurface.pane,
        externalSessionId: 'ext-1',
      ),
    );

    return ProviderScope(
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
              agentId: AgentIds.claudeCode,
              sessionId: id,
              status: AgentActivityStatus.idle,
              observedAt: testTime,
              source: AgentStatusSource.none,
            ),
          ),
        ),
        sessionChatTranscriptProvider.overrideWith(
          (ref, id) => Stream.value(messages),
        ),
        subagentTurnsReaderProvider.overrideWithValue((path) async {
          reads.add(path);
          return turns[path] ?? const [];
        }),
      ],
      child: const MaterialApp(
        home: Scaffold(body: SessionTranscriptView(sessionId: 's1')),
      ),
    );
  }

  /// The tile on its own, which is what the window matrix measures: the view
  /// around it carries a composer, a delivery strip and an approval card that
  /// are not this feature's.
  Widget tileOnly(
    SubagentRef target,
    Map<String, List<TranscriptMessage>> turns,
  ) => ProviderScope(
    overrides: [
      subagentTurnsReaderProvider.overrideWithValue((path) async {
        reads.add(path);
        return turns[path] ?? const [];
      }),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SubagentTurnsTile(reference: target),
        ),
      ),
    ),
  );

  /// Room for the whole conversation. These tests are about *what* renders;
  /// whether it fits is measured by the window matrix at the bottom, and a
  /// default 800x600 surface would scroll the parent's last turn out of the
  /// list and out of the widget tree with it.
  void roomy(WidgetTester tester) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 2000);
    addTearDown(tester.view.reset);
  }

  setUp(reads.clear);

  testWidgets('a Task call with a subagent renders its turns when expanded', (
    tester,
  ) async {
    roomy(tester);
    final ref = reference();
    await tester.pumpWidget(
      build(
        messages: transcript(subagent: ref),
        turns: {ref.filePath: delegateTurns},
      ),
    );
    await tester.pumpAndSettle();

    // Collapsed: the row says what the delegate was asked to do — a fan-out of
    // ten of these must not bury the conversation that spawned them.
    expect(find.textContaining('survey the readers'), findsWidgets);
    expect(find.text('Explore'), findsOneWidget);
    expect(find.textContaining('only one reader opens a path'), findsNothing);

    await tester.tap(find.byTooltip('Show what this subagent did'));
    await tester.pumpAndSettle();

    expect(find.textContaining('only one reader opens a path'), findsOneWidget);
    expect(find.text('GREP'), findsOneWidget);
    // The parent conversation is still there around it.
    expect(find.textContaining('the survey came back'), findsOneWidget);
  });

  testWidgets('an unexpanded subagent is never read', (tester) async {
    roomy(tester);
    final ref = reference();
    await tester.pumpWidget(
      build(
        messages: transcript(subagent: ref),
        turns: {ref.filePath: delegateTurns},
      ),
    );
    await tester.pumpAndSettle();

    expect(reads, isEmpty, reason: 'the row is collapsed; nothing to read yet');

    await tester.tap(find.byTooltip('Show what this subagent did'));
    await tester.pumpAndSettle();
    expect(reads, [ref.filePath]);

    // Collapsing and re-expanding does not pay for it again.
    await tester.tap(find.byTooltip('Hide what this subagent did'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Show what this subagent did'));
    await tester.pumpAndSettle();
    expect(reads, [ref.filePath]);
  });

  testWidgets('a Task call without a subagent renders as it does today', (
    tester,
  ) async {
    roomy(tester);
    await tester.pumpWidget(build(messages: transcript()));
    await tester.pumpAndSettle();

    expect(find.text('TASK'), findsOneWidget);
    expect(find.textContaining('survey the readers'), findsWidgets);
    expect(find.byTooltip('Show what this subagent did'), findsNothing);
    expect(reads, isEmpty);
  });

  testWidgets('a nested subagent says how deep it ran', (tester) async {
    roomy(tester);
    // spawnDepth > 1: a delegate that delegated again. The row has to say so,
    // because at depth 2 the description alone reads like a sibling.
    final outer = reference();
    final inner = reference(
      toolUseId: 'toolu_deep',
      description: 'read the store',
      agentType: 'general-purpose',
      spawnDepth: 2,
    );
    await tester.pumpWidget(
      build(
        messages: transcript(subagent: outer),
        turns: {
          outer.filePath: [
            TranscriptMessage(
              role: 'tool',
              text: 'Task(read the store)',
              tool: const ToolActivity(
                name: 'Task',
                subject: 'read the store',
              ),
              subagent: inner,
            ),
          ],
          inner.filePath: [
            const TranscriptMessage(role: 'agent', text: 'the store is flat'),
          ],
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Show what this subagent did'));
    await tester.pumpAndSettle();
    expect(find.text('general-purpose'), findsOneWidget);
    expect(find.textContaining('depth 2'), findsOneWidget);
    expect(reads, [outer.filePath]);

    await tester.tap(find.byTooltip('Show what this subagent did'));
    await tester.pumpAndSettle();
    expect(find.textContaining('the store is flat'), findsOneWidget);
    expect(reads, [outer.filePath, inner.filePath]);
  });

  testWidgets('the subagent row survives the window matrix', (tester) async {
    final ref = reference();
    await expectSurvivesWindowMatrix(
      tester,
      matrix: const [minimumWindow, desktopWindow],
      build: () => tileOnly(ref, {ref.filePath: delegateTurns}),
      // Expanded is the state with something to overflow: the delegate's turns
      // are indented inside a row that is already indented.
      warmUp: (tester) async {
        await tester.tap(find.byTooltip('Show what this subagent did'));
        await tester.pumpAndSettle();
      },
      because: 'a fan-out has to read at 720x560 as well as at 1440x900',
    );
  });

  testWidgets('an expanded subagent adds no overflow to the whole view', (
    tester,
  ) async {
    // The same two window sizes, with the conversation, the composer and the
    // delivery strip around it. **Semantics is on**: the unnamed 48x48 button
    // this originally inherited was the composer's send button, now named, so
    // the check passes and this surface is held to it. **Focus is on too**,
    // since Loop 91: expanding a subagent is what used to push the ring past
    // its 13th stop and into a revisit, because growing the list below the
    // fold made Tab scroll it mid-traversal. The transcript is its own
    // `FocusTraversalGroup` now, so this surface is held to the ring as well.
    final ref = reference();
    await expectSurvivesWindowMatrix(
      tester,
      matrix: const [minimumWindow, desktopWindow],
      build: () => build(
        messages: transcript(subagent: ref),
        turns: {ref.filePath: delegateTurns},
      ),
      warmUp: (tester) async {
        await tester.tap(find.byTooltip('Show what this subagent did'));
        await tester.pumpAndSettle();
      },
      because: 'the row is drawn inside the parent conversation, not beside it',
    );
  });
}
