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
  // Unmounts the strip and mounts it again within one scope.
  final shown = ValueNotifier(true);
  setUp(() => shown.value = true);

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
    Size? size,
  }) async {
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }
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
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // The footer gives it what the composer leaves, flexibly.
                Flexible(
                  child: ValueListenableBuilder(
                    valueListenable: shown,
                    builder: (context, shown, _) => shown
                        ? const BackgroundRunsStrip(sessionId: 's1')
                        : const SizedBox.shrink(),
                  ),
                ),
              ],
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
    expect(find.textContaining('done ·'), findsOneWidget);
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

  /// The owner's long-lived session: eight commands still running, the
  /// oldest for 16 hours, and thirteen that finished hours ago.
  List<TranscriptMessage> longLived({int running = 8, int done = 13}) => [
    for (var i = 0; i < running; i++)
      launch(
        'r$i',
        'Running $i',
        BackgroundRunState.running,
        kind: BackgroundRunKind.command,
        at: issued.subtract(Duration(hours: 16, minutes: 48 - i)),
      ),
    for (var i = 0; i < done; i++)
      launch(
        'd$i',
        'Done $i',
        BackgroundRunState.completed,
        kind: BackgroundRunKind.command,
        at: issued.subtract(Duration(hours: 12, minutes: i)),
        endedAt: issued.subtract(Duration(hours: 1, minutes: i)),
      ),
  ];

  for (final (name, size) in [
    ('phone', const Size(390, 844)),
    ('desktop', const Size(1440, 900)),
  ]) {
    testWidgets('on a $name, twenty-one runs fold to one line saying what '
        'runs and how many are done', (tester) async {
      await pump(tester, longLived(), size: size);

      expect(find.text('8 background commands running'), findsOneWidget);
      expect(find.text('13 done'), findsOneWidget);
      expect(find.text('Running 0'), findsNothing);
      expect(
        tester.getSize(find.byType(BackgroundRunsStrip)).height,
        lessThan(48),
      );
    });

    testWidgets('on a $name, unfolded it lists only the running ones, and '
        'the choice outlasts the strip', (tester) async {
      await pump(tester, longLived(), size: size);

      await tester.tap(find.text('8 background commands running'));
      await tester.pump();

      expect(find.text('Running 0'), findsOneWidget);
      expect(find.text('Done 0'), findsNothing);

      shown.value = false;
      await tester.pump();
      shown.value = true;
      // Its transcript is read again, a frame later.
      await tester.pump();
      await tester.pump();
      expect(find.text('Running 0'), findsOneWidget);

      await tester.tap(find.text('8 background commands running'));
      await tester.pump();
      expect(find.text('Running 0'), findsNothing);
    });

    testWidgets('on a $name, twenty-one running take at most a third of the '
        'view and scroll', (tester) async {
      await pump(tester, longLived(running: 21, done: 0), size: size);

      await tester.tap(find.text('21 background commands running'));
      await tester.pump();

      expect(
        tester.getSize(find.byType(BackgroundRunsStrip)).height,
        lessThanOrEqualTo(size.height / 3),
      );
      await tester.scrollUntilVisible(
        find.text('Running 20'),
        40,
        scrollable: find.descendant(
          of: find.byType(BackgroundRunsStrip),
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.text('Running 20'), findsOneWidget);
    });
  }

  testWidgets('a run that finished a while ago drops out of the list and is '
      'counted as done; one that just finished stays', (tester) async {
    final now = issued.add(const Duration(minutes: 40));
    await pump(tester, [
      launch('r', 'Still going', BackgroundRunState.running),
      launch(
        'old',
        'Finished long ago',
        BackgroundRunState.completed,
        endedAt: issued.add(const Duration(minutes: 5)),
      ),
      launch(
        'new',
        'Just finished',
        BackgroundRunState.completed,
        endedAt: now.subtract(const Duration(minutes: 1)),
      ),
    ], now: now);

    expect(find.text('Still going'), findsOneWidget);
    expect(find.text('Just finished'), findsOneWidget);
    expect(find.text('Finished long ago'), findsNothing);
    expect(find.text('2 done'), findsOneWidget);
  });
}
