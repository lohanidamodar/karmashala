import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// **The phone's composer is one compact row** (owner, 2026-10-09): the
/// tools fold into one "+" on a phone's width, Send and Stop are compact
/// circles in a thumb's tap area, and the agent switch sits on the same row.
/// And a delivered message the transcript already shows is not drawn again
/// under it.
void main() {
  late TestMachine db;
  late FakeDataServer server;

  setUp(() {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(
        id: 'acp',
        agentId: AgentIds.claudeAcp,
        path: r'C:\Users\me\.bin\claude-agent-acp.exe',
      ),
    );
    server.sessionWork
      ..typesSends = true
      ..running.add('s')
      ..busy.add('s');
    db.server.sessionRows.insert(
      session(
        id: 's',
        agentInstallationId: 'acp',
        status: SessionStatus.running,
      ),
    );
  });

  Future<void> pump(
    WidgetTester tester, {
    required Size size,
    double scale = 1.0,
    bool touch = true,
    List<TranscriptMessage> transcript = const [],
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final density = touch ? UiDensity.touch : UiDensity.pointer;
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        ...fakeTerminalOverrides(machine: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        serverOfferProvider.overrideWithValue(
          const ServerOffer(
            sameMachine: true,
            serverOs: 'windows',
            features: {
              'sessions.send',
              'sessions.interrupt',
              'sessions.send.resumes',
              'sessions.queue',
              'sessions.switchAgent',
            },
          ),
        ),
        sessionRunningOnHostProvider.overrideWithValue((_) => true),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => Stream.value(
            AgentStatusReport(
              agentId: AgentIds.claudeAcp,
              sessionId: id,
              status: AgentActivityStatus.working,
              observedAt: testTime,
              source: AgentStatusSource.protocol,
            ),
          ),
        ),
        sessionChatTranscriptProvider.overrideWith(
          (ref, id) => Stream.value(transcript),
        ),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        sessionDeliveryProvider.overrideWith(
          (ref, _) async => SessionDelivery.unknown,
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: density.themeFor(AppTheme.dark()),
          home: Scaffold(
            body: UiDensityScope(
              density: density,
              child: const SessionTranscriptView(sessionId: 's'),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  final stop = find.byKey(const ValueKey('composer-stop'));
  final agent = find.byKey(const ValueKey('switch-agent'));

  for (final width in [360.0, 412.0]) {
    for (final scale in [1.0, 1.6]) {
      testWidgets('at $width px and text ×$scale it is one row: one "+", '
          'the agent switch beside a compact Stop', (tester) async {
        await pump(tester, size: Size(width, 760), scale: scale);

        expect(tester.takeException(), isNull, reason: 'nothing overflows');
        expect(find.byKey(const ValueKey('composer-tools')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('composer-mention-button')),
          findsNothing,
          reason: 'folded into "+"',
        );
        expect(find.byTooltip('Insert a snippet'), findsNothing);
        // The circle is compact; the tap area around it is a thumb's.
        final circle = tester.getSize(
          find.descendant(of: stop, matching: find.byType(Material)).first,
        );
        expect(circle.width, Touch.compactControl);
        expect(tester.getSize(stop).height, greaterThanOrEqualTo(Touch.target));
        // The switch shares Stop's row rather than taking one of its own.
        expect(
          (tester.getCenter(agent).dy - tester.getCenter(stop).dy).abs(),
          lessThan(Touch.target / 2),
        );
        expect(tester.getCenter(agent).dx, lessThan(tester.getCenter(stop).dx));
      });
    }
  }

  testWidgets('"+" lists attaching, snippets and mentions', (tester) async {
    await pump(tester, size: const Size(360, 760));
    await tester.tap(find.byKey(const ValueKey('composer-tools')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('composer-tool-attach')), findsOneWidget);
    expect(find.byKey(const ValueKey('composer-tool-snippet')), findsOneWidget);
    expect(find.byKey(const ValueKey('composer-tool-mention')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('composer-tool-mention')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('composer-mention-search')), findsOne);
  });

  testWidgets('a wide touch screen keeps each tool its own button', (
    tester,
  ) async {
    await pump(tester, size: const Size(800, 900));
    expect(find.byKey(const ValueKey('composer-tools')), findsNothing);
    expect(
      find.byKey(const ValueKey('composer-mention-button')),
      findsOneWidget,
    );
    expect(find.byTooltip('Insert a snippet'), findsOneWidget);
  });

  testWidgets('the desktop composer keeps its toolbar and named agent switch', (
    tester,
  ) async {
    await pump(tester, size: const Size(1100, 700), touch: false);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('composer-tools')), findsNothing);
    expect(find.textContaining('Claude'), findsWidgets);
  });

  Future<void> deliver(WidgetTester tester) async {
    server.sessionWork.queues['s'] = [
      QueuedMessage(
        id: 'q1',
        sessionId: 's',
        seq: 1,
        text: 'gh CLI is on wsl',
        state: QueuedMessageState.queued,
        origin: QueuedMessageOrigin.app,
        createdAt: testTime,
        updatedAt: testTime,
      ),
    ];
    server.sessionWork.holdQueue('s', null);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    server.sessionWork.deliverHead('s');
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('a delivered message already in the transcript is shown once', (
    tester,
  ) async {
    await pump(
      tester,
      size: const Size(412, 760),
      transcript: [
        TranscriptMessage(role: 'user', text: 'gh CLI is on wsl', at: testTime),
      ],
    );
    await deliver(tester);

    expect(find.text('Delivered'), findsNothing);
    expect(find.text('gh CLI is on wsl'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('one the transcript has yet to show is marked Delivered', (
    tester,
  ) async {
    await pump(tester, size: const Size(412, 760));
    await deliver(tester);

    expect(find.text('Delivered'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });
}
