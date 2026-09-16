import 'dart:async';

import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_signals.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/launch.dart';
import 'package:agent_cli/stream.dart';
import 'package:karmashala/src/features/sessions/presentation/activity_strip.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import 'package:karmashala_ui/rows.dart';

/// **What the live-activity strip costs.** Counted, never timed.
///
/// The owner's constraint is specific: the transcript is re-parsed on a
/// two-second poll and their largest session is 15 MB (Claude) / 120 MB
/// (Codex). So the three numbers that matter are how many times the transcript
/// is subscribed to, how many times the conversation above the strip is rebuilt
/// while the elapsed clock ticks, and how many timers exist.
class _MovingClock implements Clock {
  _MovingClock(this.now);

  DateTime now;

  @override
  DateTime nowUtc() => now;
}

void main() {
  final issued = DateTime.utc(2026, 9, 2, 10);

  /// How many one-second ticks the clock is driven through.
  const ticks = 10;

  TranscriptMessage call({
    required String id,
    String subject = 'git status',
    bool answered = false,
  }) => TranscriptMessage(
    role: 'tool',
    text: 'Bash($subject)',
    tool: ToolActivity(
      name: 'Bash',
      subject: subject,
      output: answered ? 'clean' : null,
    ),
    at: issued,
    pendingToolUseId: answered ? null : id,
  );

  late int subscriptions;
  late AppDatabase db;

  setUp(() {
    subscriptions = 0;
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
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
  });

  tearDown(() => db.close());

  // Inferred, because Riverpod's `Override` is not an exported type.
  // ignore: strict_top_level_inference
  overrides({
    required List<TranscriptMessage> messages,
    required Clock clock,
  }) => [
    databaseProvider.overrideWithValue(db),
    clockProvider.overrideWithValue(clock),
    agentSessionStatusProvider.overrideWith(
      (ref, id) => Stream.value(
        AgentStatusReport(
          agentId: AgentIds.claudeCode,
          sessionId: id,
          status: AgentActivityStatus.working,
          observedAt: testTime,
          source: AgentStatusSource.stateFile,
        ),
      ),
    ),
    // Counted rather than faked away: the whole claim is that the strip reads
    // the parse the conversation already does, so a second subscription here
    // would be a second poll and a second parse of a 120 MB file.
    sessionChatTranscriptProvider.overrideWith((ref, id) {
      subscriptions++;
      return Stream.value(messages);
    }),
  ];

  Future<void> pumpConversation(
    WidgetTester tester, {
    required List<TranscriptMessage> messages,
    required Clock clock,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...fakeTerminalOverrides(),
          ...overrides(messages: messages, clock: clock),
          availableSystemTerminalsProvider.overrideWith(
            (ref) async => const <SystemTerminal>[],
          ),
          sessionDeliveryProvider.overrideWith(
            (ref, _) async => SessionDelivery.unknown,
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SessionTranscriptView(sessionId: 's1')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the strip reads the parse the conversation already does', (
    tester,
  ) async {
    await pumpConversation(
      tester,
      messages: [call(id: 't1')],
      clock: _MovingClock(issued.add(const Duration(seconds: 4))),
    );

    expect(find.byType(ActivityStrip), findsOneWidget);
    expect(find.text('Bash(git status)'), findsWidgets);
    expect(
      subscriptions,
      1,
      reason: 'one subscription serves the transcript and the strip — no '
          'second read, no second poll',
    );
  });

  testWidgets('$ticks clock ticks rebuild the strip and nothing above it', (
    tester,
  ) async {
    final clock = _MovingClock(issued.add(const Duration(seconds: 4)));
    await pumpConversation(tester, messages: [call(id: 't1')], clock: clock);

    // The widget object itself: if the conversation had been rebuilt, its
    // parent would have handed `ChatTranscriptView` a freshly mapped message
    // list inside a new widget instance.
    final before = tester.widget<ChatTranscriptView>(
      find.byType(ChatTranscriptView),
    );
    expect(find.text('4s'), findsOneWidget);

    var rebuilds = 0;
    for (var i = 1; i <= ticks; i++) {
      clock.now = issued.add(Duration(seconds: 4 + i));
      await tester.pump(kActivityTickInterval);
      final now = tester.widget<ChatTranscriptView>(
        find.byType(ChatTranscriptView),
      );
      if (!identical(before, now)) rebuilds++;
    }

    expect(
      rebuilds,
      0,
      reason: 'the elapsed clock must not repaint the transcript',
    );
    expect(subscriptions, 1, reason: 'nor re-read it');
    // ...and the strip itself did move, so the zero above is isolation rather
    // than a clock that never ran.
    expect(find.text('${4 + ticks}s'), findsOneWidget);
  });

  testWidgets('a title change never wakes the strip', (tester) async {
    // `sessionsRevisionProvider` used to be one counter with sixteen bump
    // sites; the CLI store sweep renames sessions on its own timer, so waking
    // on `title` would mean waking on nothing the user did.
    final clock = _MovingClock(issued.add(const Duration(seconds: 4)));
    await pumpConversation(tester, messages: [call(id: 't1')], clock: clock);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ActivityStrip)),
    );
    container
        .read(sessionsRevisionProvider.notifier)
        .changed(const SessionChange.renamed('s1'));
    await tester.pump();

    expect(subscriptions, 1);
    expect(find.text('4s'), findsOneWidget);
  });

  group('the tick exists only while there is something to count', () {
    /// The strip on its own, so every periodic timer counted is the strip's.
    Future<int> periodicTimersFor(
      WidgetTester tester,
      List<TranscriptMessage> messages, {
      int pumps = 0,
    }) async {
      var timers = 0;
      await runZoned(
        () async {
          await tester.pumpWidget(
            ProviderScope(
              overrides: overrides(
                messages: messages,
                clock: _MovingClock(issued.add(const Duration(seconds: 4))),
              ),
              child: const MaterialApp(
                home: Scaffold(body: ActivityStrip(sessionId: 's1')),
              ),
            ),
          );
          await tester.pump();
          for (var i = 0; i < pumps; i++) {
            await tester.pump(kActivityTickInterval);
          }
        },
        zoneSpecification: ZoneSpecification(
          createPeriodicTimer: (self, parent, zone, period, f) {
            timers++;
            return parent.createPeriodicTimer(zone, period, f);
          },
        ),
      );
      return timers;
    }

    testWidgets('nothing outstanding starts no timer', (tester) async {
      final timers = await periodicTimersFor(tester, [
        call(id: 't1', answered: true),
      ]);

      expect(timers, 0, reason: 'a quiet session must cost nothing');
    });

    testWidgets('one outstanding call arms exactly one, and keeps it', (
      tester,
    ) async {
      final timers = await periodicTimersFor(
        tester,
        [call(id: 't1')],
        pumps: ticks,
      );

      expect(
        timers,
        1,
        reason: 'armed once, not once per rebuild — and `testWidgets` fails '
            'this test if it is still pending after the tree comes down',
      );
    });
  });
}
