import 'dart:async';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/sessions/application/acp_session_providers.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_activity_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_usage_providers.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SessionUsageChanged;
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:agent_cli/stream.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala/src/features/sessions/presentation/working_line.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
import '../terminal/fake_instance.dart';
import 'package:karmashala_ui/rows.dart';

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

  AgentStatusReport report({
    AgentActivityStatus status = AgentActivityStatus.working,
    AgentWorkingDetail? working,
    AgentWaitKind waiting = AgentWaitKind.unrecorded,
  }) => AgentStatusReport(
    agentId: AgentIds.claudeCode,
    sessionId: 's1',
    status: status,
    observedAt: issued,
    source: AgentStatusSource.hook,
    waiting: waiting,
    working: working,
  );

  // The return type is inferred: Riverpod's `Override` is a sealed type its
  // public library does not export, so it cannot be written down here.
  // ignore: strict_top_level_inference
  overridesFor({
    required List<TranscriptMessage> messages,
    required Clock clock,
    required Stream<AgentStatusReport> statuses,
    SessionStatus rowStatus = SessionStatus.running,
    SessionSurface surface = SessionSurface.pane,
    required TestMachine db,
    bool acp = false,
    int? contextUsed,
  }) async {
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
        title: 'Session',
        useWorktree: false,
        status: rowStatus,
        createdAt: testTime,
        surface: surface,
        externalSessionId: 'ext-1',
      ),
    );
    return [
      await server.override(),
      clockProvider.overrideWithValue(clock),
      agentSessionStatusProvider.overrideWith((ref, id) => statuses),
      sessionChatTranscriptProvider.overrideWith(
        (ref, id) => Stream.value(messages),
      ),
      if (acp) ...[
        isAcpSessionProvider.overrideWith((ref, id) => true),
        sessionUsageProvider.overrideWith(
          (ref, id) => contextUsed == null
              ? null
              : SessionUsageChanged(
                  sessionId: id,
                  contextUsed: contextUsed,
                  contextSize: 200000,
                ),
        ),
      ],
    ];
  }

  /// The line on its own, which is what most of these tests are about.
  Future<void> pumpLine(
    WidgetTester tester, {
    required List<TranscriptMessage> messages,
    Clock? clock,
    Stream<AgentStatusReport>? statuses,
    AgentActivityStatus status = AgentActivityStatus.working,
    SessionStatus rowStatus = SessionStatus.running,
    SessionSurface surface = SessionSurface.pane,
    bool acp = false,
    int? contextUsed,
    VoidCallback? onStop,
  }) async {
    final db = TestMachine();
    await tester.pumpWidget(
      ProviderScope(
        overrides: await overridesFor(
          messages: messages,
          clock: clock ?? FixedClock(issued.add(const Duration(seconds: 4))),
          statuses: statuses ?? Stream.value(report(status: status)),
          rowStatus: rowStatus,
          surface: surface,
          db: db,
          acp: acp,
          contextUsed: contextUsed,
        ),
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [WorkingLine(sessionId: 's1', onStop: onStop)],
            ),
          ),
        ),
      ),
    );
    // Twice: both sources are streams, so the first frame is drawn before
    // either has answered.
    await tester.pump();
    await tester.pump();
  }

  Finder meta(String text) => find.text(' · $text');

  group('what it says', () {
    testWidgets('the agent\'s own word, the turn\'s time and its tokens', (
      tester,
    ) async {
      await pumpLine(
        tester,
        messages: const [],
        statuses: Stream.value(
          report(
            working: AgentWorkingDetail(
              word: 'Booping…',
              since: issued.subtract(const Duration(seconds: 8)),
              tokens: 1234,
            ),
          ),
        ),
      );

      expect(find.text('Booping…'), findsOneWidget);
      expect(meta('12s · 1.2k tokens'), findsOneWidget);
      expect(
        tester.getSemantics(find.byType(WorkingLine)).label,
        contains('Working: Booping…'),
      );
    });

    testWidgets('its word wins over the call it is on', (tester) async {
      await pumpLine(
        tester,
        messages: [call(id: 't1')],
        statuses: Stream.value(
          report(
            working: AgentWorkingDetail(word: 'Booping…', since: issued),
          ),
        ),
      );

      expect(find.text('Booping…'), findsOneWidget);
      expect(find.text('Bash(git status)'), findsNothing);
    });

    testWidgets('with no word, the one outstanding call and how long', (
      tester,
    ) async {
      await pumpLine(tester, messages: [call(id: 't1')]);

      expect(find.text('Bash(git status)'), findsOneWidget);
      expect(meta('4s'), findsOneWidget);
    });

    testWidgets('with nothing to name, "Working…" and the turn\'s time', (
      tester,
    ) async {
      await pumpLine(
        tester,
        messages: [
          TranscriptMessage(role: 'agent', text: 'thinking', at: issued),
        ],
        statuses: Stream.value(
          report(
            working: AgentWorkingDetail(
              since: issued.subtract(const Duration(seconds: 26)),
            ),
          ),
        ),
      );

      expect(find.text('Working…'), findsOneWidget);
      expect(meta('30s'), findsOneWidget);
      expect(find.byType(SteppedRing), findsOneWidget);
    });

    testWidgets('several outstanding calls collapse to a count', (
      tester,
    ) async {
      await pumpLine(
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

      // Two shell calls and one subagent, counted apart.
      expect(find.text('2 tools and 1 subagent running'), findsOneWidget);
      expect(meta('1m 20s'), findsOneWidget);
      expect(find.text('Bash(flutter test)'), findsNothing);
      expect(find.byIcon(AppIcons.robot), findsOneWidget);
    });

    testWidgets('an Agent call reads as a subagent', (tester) async {
      await pumpLine(
        tester,
        messages: [
          call(id: 't1', name: kSubagentToolName, subject: 'review the diff'),
        ],
      );

      expect(find.text('$kSubagentToolName(review the diff)'), findsOneWidget);
      expect(
        tester.getSemantics(find.byType(WorkingLine)).label,
        contains('Subagent running'),
      );
    });

    // §19: a reading that could not be taken must never present itself as a
    // reading of zero. The line says only that it is working.
    testWidgets('a working session with no record to read says only that', (
      tester,
    ) async {
      await pumpLine(
        tester,
        messages: const [],
        surface: SessionSurface.external,
      );

      expect(find.text('Working…'), findsOneWidget);
      expect(
        find.byTooltip(activityBlindSpotDetail(ActivityBlindSpot.noRecord)),
        findsOneWidget,
      );
    });

    testWidgets('a call that has run for hours is counted in hours', (
      tester,
    ) async {
      await pumpLine(
        tester,
        clock: FixedClock(
          issued.add(const Duration(minutes: 514, seconds: 48)),
        ),
        messages: [call(id: 't1')],
      );

      expect(find.text('Bash(git status)'), findsOneWidget);
      expect(meta('8h 34m'), findsOneWidget);
    });

    testWidgets('a chat session shows the context its agent reports', (
      tester,
    ) async {
      await pumpLine(
        tester,
        messages: const [],
        acp: true,
        contextUsed: 45210,
        statuses: Stream.value(
          report(working: AgentWorkingDetail(since: issued)),
        ),
      );

      expect(find.text('Working…'), findsOneWidget);
      expect(meta('4s · 45.2k in context'), findsOneWidget);
    });

    testWidgets('a terminal session with no count shows none', (tester) async {
      await pumpLine(
        tester,
        messages: const [],
        contextUsed: 45210,
        statuses: Stream.value(
          report(working: AgentWorkingDetail(since: issued)),
        ),
      );

      expect(meta('4s'), findsOneWidget);
    });
  });

  group('when it shows', () {
    testWidgets('it appears, ticks, and is gone when the turn ends', (
      tester,
    ) async {
      final clock = _MovingClock(issued.add(const Duration(seconds: 4)));
      final statuses = StreamController<AgentStatusReport>();
      addTearDown(statuses.close);
      await pumpLine(
        tester,
        messages: const [],
        clock: clock,
        statuses: statuses.stream,
      );
      expect(tester.getSize(find.byType(WorkingLine)), Size.zero);

      statuses.add(
        report(
          working: AgentWorkingDetail(
            word: 'Sautéing…',
            since: issued,
            tokens: 7,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Sautéing…'), findsOneWidget);
      expect(meta('4s · 7 tokens'), findsOneWidget);

      clock.now = issued.add(const Duration(seconds: 5));
      await tester.pump(kActivityTickInterval);
      expect(meta('5s · 7 tokens'), findsOneWidget);

      statuses.add(report(status: AgentActivityStatus.idle));
      await tester.pump();
      await tester.pump();
      expect(find.text('Sautéing…'), findsNothing);
      expect(tester.getSize(find.byType(WorkingLine)), Size.zero);
    });

    testWidgets('a question replaces it', (tester) async {
      await pumpLine(
        tester,
        messages: const [],
        statuses: Stream.value(
          report(
            status: AgentActivityStatus.awaitingApproval,
            waiting: AgentWaitKind.question,
            working: AgentWorkingDetail(word: 'Booping…', since: issued),
          ),
        ),
      );

      expect(find.text('Booping…'), findsNothing);
      expect(tester.getSize(find.byType(WorkingLine)), Size.zero);
    });

    testWidgets('an idle session shows nothing, though a call is open', (
      tester,
    ) async {
      await pumpLine(
        tester,
        messages: [call(id: 't1')],
        status: AgentActivityStatus.idle,
      );

      expect(tester.getSize(find.byType(WorkingLine)), Size.zero);
    });

    testWidgets('Stop is offered where Esc stops the turn', (tester) async {
      var stopped = 0;
      await pumpLine(
        tester,
        messages: [call(id: 't1')],
        onStop: () => stopped++,
      );
      await tester.tap(find.text('Stop · Esc'));
      expect(stopped, 1);
    });

    testWidgets('...and not where it does not', (tester) async {
      await pumpLine(
        tester,
        messages: const [],
        onStop: () {},
        statuses: Stream.value(
          report(working: AgentWorkingDetail(since: issued)),
        ),
      );
      expect(find.text('Working…'), findsOneWidget);
      expect(find.text('Stop · Esc'), findsNothing);
    });

    testWidgets('under reduced motion the mark is still', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await pumpLine(tester, messages: [call(id: 't1')]);

      final paint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(SteppedRing),
          matching: find.byType(CustomPaint),
        ),
      );
      expect((paint.painter! as SteppedRingPainter).clock, isNull);
      expect(find.text('Bash(git status)'), findsOneWidget);
    });
  });

  group('in the chat', () {
    testWidgets('it sits under the last message, above the composer', (
      tester,
    ) async {
      final db = TestMachine();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...fakeTerminalOverrides(),
            ...await overridesFor(
              messages: [
                TranscriptMessage(role: 'user', text: 'Fix it', at: issued),
                call(id: 't1'),
              ],
              clock: FixedClock(issued.add(const Duration(seconds: 4))),
              statuses: Stream.value(
                report(
                  working: AgentWorkingDetail(
                    word: 'Booping…',
                    since: issued,
                    tokens: 1200,
                  ),
                ),
              ),
              db: db,
            ),
            availableSystemTerminalsProvider.overrideWith(
              (ref) async => const <SystemTerminal>[],
            ),
            sessionRunningOnHostProvider.overrideWithValue((_) => true),
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

      final line = find.byKey(const ValueKey('chat-working-line'));
      expect(line, findsOneWidget);
      expect(find.text('Booping…'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(WorkingLine),
        ),
        findsNothing,
        reason: 'outside the scroll, so it never scrolls out of sight',
      );
      final composer = tester.getRect(find.byType(TextField).last);
      final list = tester.getRect(find.byType(ListView));
      expect(tester.getRect(line).top, greaterThanOrEqualTo(list.bottom));
      expect(tester.getRect(line).bottom, lessThanOrEqualTo(composer.top));
    });

    testWidgets('survives 360 px at text scale 1.6, and a desktop', (
      tester,
    ) async {
      final db = TestMachine();
      final overrides = await overridesFor(
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
        statuses: Stream.value(
          report(
            working: AgentWorkingDetail(
              word: 'Discombobulating…',
              since: issued.subtract(const Duration(hours: 1)),
              tokens: 123456,
            ),
          ),
        ),
        db: db,
      );
      await expectSurvivesWindowMatrix(
        tester,
        because: 'the line is one row however narrow the chat',
        matrix: const [
          WindowCell('360x760 phone, text 1.6', Size(360, 760), textScale: 1.6),
          desktopWindow,
        ],
        build: () => ProviderScope(
          overrides: overrides,
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [WorkingLine(sessionId: 's1', onStop: () {})],
              ),
            ),
          ),
        ),
      );
    });
  });
}
