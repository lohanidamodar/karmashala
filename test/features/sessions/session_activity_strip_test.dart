import 'package:karmashala/src/app/theme/app_icons.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_status.dart';
import 'package:karmashala/src/features/cli_detection/data/cli_transcript_reader.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session.dart';
import 'package:karmashala/src/features/sessions/domain/session_delivery.dart';
import 'package:karmashala/src/features/sessions/domain/session_event_types.dart';
import 'package:karmashala/src/features/sessions/domain/session_launch.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:karmashala/src/features/sessions/domain/tool_activity.dart';
import 'package:karmashala/src/features/sessions/application/session_activity_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/activity_strip.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
import '../terminal/fake_instance.dart';

/// A clock the test moves by hand, so the elapsed times are the test's own
/// arithmetic rather than the wall clock's.
class _MovingClock implements Clock {
  _MovingClock(this.now);

  DateTime now;

  @override
  DateTime nowUtc() => now;
}

void main() {
  final issued = DateTime.utc(2026, 9, 2, 10);

  TranscriptMessage call({
    required String id,
    String name = 'Bash',
    String subject = 'git status',
    DateTime? at,
    bool answered = false,
  }) => TranscriptMessage(
    role: 'tool',
    text: '$name($subject)',
    tool: ToolActivity(
      name: name,
      subject: subject,
      output: answered ? 'clean' : null,
    ),
    at: at ?? issued,
    pendingToolUseId: answered ? null : id,
  );

  // The return type is inferred: Riverpod's `Override` is a sealed type its
  // public library does not export, so it cannot be written down here.
  // ignore: strict_top_level_inference
  overridesFor({
    required List<TranscriptMessage> messages,
    required Clock clock,
    AgentActivityStatus status = AgentActivityStatus.working,
    SessionStatus rowStatus = SessionStatus.running,
    SessionSurface surface = SessionSurface.pane,
    required AppDatabase db,
  }) {
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
        status: rowStatus,
        createdAt: testTime,
        surface: surface,
        externalSessionId: 'ext-1',
      ),
    );
    return [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(clock),
      agentSessionStatusProvider.overrideWith(
        (ref, id) => Stream.value(
          AgentStatusReport(
            agentId: AgentIds.claudeCode,
            sessionId: id,
            status: status,
            observedAt: issued,
            source: AgentStatusSource.stateFile,
          ),
        ),
      ),
      sessionChatTranscriptProvider.overrideWith(
        (ref, id) => Stream.value(messages),
      ),
    ];
  }

  /// The strip on its own, which is what these tests are about: the view around
  /// it carries a composer, a delivery strip and an approval card that are not
  /// this feature's.
  Future<Clock> pumpStrip(
    WidgetTester tester, {
    required List<TranscriptMessage> messages,
    Clock? clock,
    AgentActivityStatus status = AgentActivityStatus.working,
    SessionStatus rowStatus = SessionStatus.running,
    SessionSurface surface = SessionSurface.pane,
  }) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final used = clock ?? FixedClock(issued.add(const Duration(seconds: 4)));
    await tester.pumpWidget(
      ProviderScope(
        overrides: overridesFor(
          messages: messages,
          clock: used,
          status: status,
          rowStatus: rowStatus,
          surface: surface,
          db: db,
        ),
        child: const MaterialApp(
          home: Scaffold(
            body: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [ActivityStrip(sessionId: 's1')],
            ),
          ),
        ),
      ),
    );
    // Twice: both sources are streams, so the first frame is drawn before
    // either has answered.
    await tester.pump();
    await tester.pump();
    return used;
  }

  testWidgets('one outstanding call shows what it is and how long it has run', (
    tester,
  ) async {
    await pumpStrip(tester, messages: [call(id: 't1')]);

    expect(find.text('Bash(git status)'), findsOneWidget);
    expect(find.text('4s'), findsOneWidget);
  });

  testWidgets('...and is gone the moment its result arrives', (tester) async {
    await pumpStrip(tester, messages: [call(id: 't1', answered: true)]);

    expect(find.text('Bash(git status)'), findsNothing);
    expect(tester.getSize(find.byType(ActivityStrip)), Size.zero);
  });

  // The common case, and the one the strip must cost nothing in: not an empty
  // box, not a reserved row — nothing.
  testWidgets('nothing outstanding draws nothing at all', (tester) async {
    await pumpStrip(
      tester,
      messages: [
        TranscriptMessage(role: 'agent', text: 'all done', at: issued),
      ],
    );

    expect(tester.getSize(find.byType(ActivityStrip)), Size.zero);
    expect(
      find.descendant(
        of: find.byType(ActivityStrip),
        matching: find.byType(Container),
      ),
      findsNothing,
    );
  });

  testWidgets('several outstanding calls collapse to a count', (tester) async {
    await pumpStrip(
      tester,
      clock: FixedClock(issued.add(const Duration(minutes: 1, seconds: 20))),
      messages: [
        call(id: 't1', subject: 'flutter test'),
        call(
          id: 't2',
          subject: 'git log',
          at: issued.add(const Duration(seconds: 30)),
        ),
        call(
          id: 't3',
          name: kSubagentToolName,
          subject: 'review the diff',
          at: issued.add(const Duration(seconds: 40)),
        ),
      ],
    );

    // Two shell calls and one subagent, counted apart: a collapsed label that
    // said "3 tools running" hid the one call that is another agent.
    expect(find.text('2 tools and 1 subagent running'), findsOneWidget);
    // The oldest is the one worth naming — it is what the reader is waiting on.
    expect(find.text('oldest 1m 20s'), findsOneWidget);
    expect(find.text('Bash(flutter test)'), findsNothing);
    expect(find.byIcon(AppIcons.robot), findsOneWidget);
  });

  testWidgets('several subagents at once say so', (tester) async {
    await pumpStrip(
      tester,
      messages: [
        call(id: 't1', name: kSubagentToolName, subject: 'review the diff'),
        call(
          id: 't2',
          name: kSubagentToolName,
          subject: 'survey the API',
          at: issued.add(const Duration(seconds: 5)),
        ),
      ],
    );

    expect(find.text('2 subagents running'), findsOneWidget);
  });

  testWidgets('an Agent call reads as a subagent', (tester) async {
    await pumpStrip(
      tester,
      messages: [
        call(id: 't1', name: kSubagentToolName, subject: 'review the diff'),
      ],
    );

    expect(find.text('$kSubagentToolName(review the diff)'), findsOneWidget);
    // Not colour alone: the semantics say which kind of call this is, which is
    // also what Narrator reads.
    final semantics = tester.getSemantics(find.byType(ActivityStrip));
    expect(semantics.label, contains('Subagent running'));
  });

  // The trap, drawn: a session that is not working shows nothing even though
  // its transcript ends on an unanswered call.
  testWidgets('a session that is not working shows nothing', (tester) async {
    await pumpStrip(
      tester,
      messages: [call(id: 't1')],
      status: AgentActivityStatus.idle,
    );

    expect(tester.getSize(find.byType(ActivityStrip)), Size.zero);
  });

  // **The measurement that replaced the thirty-minute ceiling.** The longest
  // unanswered tool window in the owner's Claude Code store is a `Bash` call at
  // 514.8 minutes, and the old strip retired it at thirty — while the session's
  // own badge still said Working. What decides it now is that badge.
  testWidgets('a call that has run for hours is still shown', (tester) async {
    await pumpStrip(
      tester,
      clock: FixedClock(issued.add(const Duration(minutes: 514, seconds: 48))),
      messages: [call(id: 't1')],
    );

    expect(find.text('Bash(git status)'), findsOneWidget);
    expect(find.text('8h 34m'), findsOneWidget);
  });

  // §19: a reading that could not be taken must never present itself as a
  // reading of zero. An empty strip beside a badge reading Working is exactly
  // that, so the one case where we cannot look says so.
  testWidgets('a working session with no record to read says so', (
    tester,
  ) async {
    await pumpStrip(tester, messages: const [], surface: SessionSurface.external);

    expect(
      find.text(activityBlindSpotSentence(ActivityBlindSpot.noRecord)),
      findsOneWidget,
    );
    expect(find.byIcon(AppIcons.question), findsOneWidget);
  });

  testWidgets('...and an idle one with no record stays silent', (tester) async {
    await pumpStrip(
      tester,
      messages: const [],
      surface: SessionSurface.external,
      status: AgentActivityStatus.idle,
    );

    expect(tester.getSize(find.byType(ActivityStrip)), Size.zero);
  });

  testWidgets('the elapsed time advances on its own', (tester) async {
    final clock = _MovingClock(issued.add(const Duration(seconds: 4)));
    await pumpStrip(tester, messages: [call(id: 't1')], clock: clock);

    expect(find.text('4s'), findsOneWidget);

    clock.now = issued.add(const Duration(seconds: 5));
    await tester.pump(kActivityTickInterval);

    expect(find.text('5s'), findsOneWidget);
    expect(find.text('4s'), findsNothing);
  });

  testWidgets('the strip is pinned above the composer in the chat view', (
    tester,
  ) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // No database here: `overridesFor` supplies it, and overriding one
          // provider twice is an error.
          ...fakeTerminalOverrides(),
          ...overridesFor(
            messages: [call(id: 't1')],
            clock: FixedClock(issued.add(const Duration(seconds: 4))),
            db: db,
          ),
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

    expect(find.byType(ActivityStrip), findsOneWidget);
    expect(find.text('Bash(git status)'), findsWidgets);
  });

  testWidgets('survives the window matrix', (tester) async {
    await expectSurvivesWindowMatrix(
      tester,
      because: 'the chat view is already tight at 720 and the strip sits in it',
      build: () {
        final db = AppDatabase.memory();
        addTearDown(db.close);
        return ProviderScope(
          overrides: overridesFor(
            messages: [
              call(
                id: 't1',
                subject:
                    'flutter test --exclude-tags=live-ssh,live-wsl '
                    '--concurrency=4 test/features/sessions',
              ),
              call(
                id: 't2',
                name: kSubagentToolName,
                subject: 'review the whole diff and report back',
                at: issued.add(const Duration(seconds: 30)),
              ),
            ],
            clock: FixedClock(issued.add(const Duration(minutes: 2))),
            db: db,
          ),
          child: const MaterialApp(
            home: Scaffold(
              body: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [ActivityStrip(sessionId: 's1')],
              ),
            ),
          ),
        );
      },
    );
  });
}
