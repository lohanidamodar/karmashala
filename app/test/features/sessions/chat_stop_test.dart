import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_turn_stop.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// **Stop is there whenever the agent works** — by the server's status, not
/// only while a tool call is in flight: the composer's round button turns to
/// Stop (■), Esc stops from anywhere in the chat, the turn's footer says
/// "Stopped", and a turn that runs on past the grace offers to end the
/// session instead.
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late StreamController<AgentStatusReport> statuses;

  const phone = Size(390, 844);
  const desktop = Size(1440, 900);

  AgentStatusReport report(AgentActivityStatus status) => AgentStatusReport(
    agentId: AgentIds.claudeAcp,
    sessionId: 'acp-1',
    status: status,
    observedAt: testTime,
    source: AgentStatusSource.protocol,
  );

  setUp(() async {
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
      ..running.add('acp-1')
      ..busy.add('acp-1');
    db.server.sessionRows.insert(
      session(
        id: 'acp-1',
        agentInstallationId: 'acp',
        status: SessionStatus.running,
      ),
    );
    statuses = StreamController<AgentStatusReport>.broadcast();
  });

  tearDown(() => statuses.close());

  /// The working spinner never settles, so frames are pumped, not settled.
  Future<void> frames(WidgetTester tester, [int count = 10]) async {
    for (var i = 0; i < count; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pump(
    WidgetTester tester, {
    required Size size,
    bool touch = false,
    bool peek = false,
    bool phonePage = false,
    List<TranscriptMessage> messages = const [],
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
              'sessions.queue.control',
              'sessions.queue.manage',
            },
          ),
        ),
        sessionRunningOnHostProvider.overrideWithValue((_) => true),
        agentSessionStatusProvider.overrideWith((ref, id) => statuses.stream),
        sessionChatTranscriptProvider.overrideWith(
          (ref, id) => Stream.value(messages),
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
          home: UiDensityScope(
            density: touch ? UiDensity.touch : UiDensity.pointer,
            child: Scaffold(
              // The peek and the phone's page build the same view, each
              // with its own flags.
              body: SessionTranscriptView(
                sessionId: 'acp-1',
                resumesInBackground: peek,
                holdForPrompt: phonePage,
              ),
            ),
          ),
        ),
      ),
    );
    await frames(tester);
  }

  Future<void> working(WidgetTester tester, AgentActivityStatus status) async {
    statuses.add(report(status));
    await frames(tester);
  }

  final stop = find.byKey(const ValueKey('composer-stop'));
  final escHint = find.byKey(const ValueKey('chat-working-esc-hint'));
  // Every control that stops the turn says so to a screen reader.
  final stopControls = find.byWidgetPredicate(
    (w) =>
        w is Semantics &&
        (w.properties.label?.startsWith('Stop the running turn') ?? false),
  );

  for (final (name, size, touch) in [
    ('phone', phone, true),
    ('desktop', desktop, false),
  ]) {
    testWidgets('on a $name, Send turns to Stop while the agent works with '
        'no call in flight, and back once it stops', (tester) async {
      await pump(tester, size: size, touch: touch);
      expect(stop, findsNothing);

      await working(tester, AgentActivityStatus.working);
      expect(stop, findsOneWidget);
      expect(
        tester.widget<IconButton>(stop).tooltip,
        touch ? 'Stop' : 'Stop · Esc',
      );
      // One Stop: the working line names Esc on a desktop, as text only.
      expect(find.byKey(const ValueKey('chat-working-line')), findsOneWidget);
      expect(stopControls, findsOneWidget);
      expect(escHint, touch ? findsNothing : findsOneWidget);
      if (touch) {
        final box = tester.getSize(stop);
        expect(box.width, greaterThanOrEqualTo(Touch.target));
        expect(box.height, greaterThanOrEqualTo(Touch.target));
      }

      await tester.tap(stop);
      await frames(tester);
      expect(server.sessionWork.interrupts, ['acp-1']);

      await working(tester, AgentActivityStatus.idle);
      expect(stop, findsNothing);
      // The composer is ready for the next message.
      final box = tester.widget<TextField>(find.byType(TextField).last);
      expect(box.enabled ?? true, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  for (final (name, size, touch, peek) in [
    ('the dashboard peek', desktop, false, true),
    ('the phone peek', phone, true, true),
    ('the phone session page', phone, true, false),
  ]) {
    testWidgets('$name offers the same Stop', (tester) async {
      await pump(
        tester,
        size: size,
        touch: touch,
        peek: peek,
        phonePage: !peek,
      );
      await working(tester, AgentActivityStatus.working);
      expect(stop, findsOneWidget);
      expect(stopControls, findsOneWidget);
      expect(escHint, touch ? findsNothing : findsOneWidget);
      await tester.tap(stop);
      await frames(tester);
      expect(server.sessionWork.interrupts, ['acp-1']);
      await working(tester, AgentActivityStatus.idle);
      expect(stop, findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a desktop window too narrow for the hint drops it', (
    tester,
  ) async {
    await pump(tester, size: phone);
    await working(tester, AgentActivityStatus.working);
    expect(find.byKey(const ValueKey('chat-working-line')), findsOneWidget);
    expect(stopControls, findsOneWidget);
    expect(escHint, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Esc stops while the agent works with no call in flight, and '
      'is left alone while it is idle', (tester) async {
    await pump(tester, size: desktop);
    await tester.tap(find.byType(TextField).last);
    await frames(tester, 2);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await frames(tester, 2);
    expect(server.sessionWork.interrupts, isEmpty);

    await working(tester, AgentActivityStatus.working);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await frames(tester);
    expect(server.sessionWork.interrupts, ['acp-1']);
    await working(tester, AgentActivityStatus.idle);
  });

  testWidgets('typing while it works shows Send beside Stop, and Send still '
      'queues', (tester) async {
    await pump(tester, size: desktop);
    await working(tester, AgentActivityStatus.working);

    await tester.enterText(find.byType(TextField).last, 'then run the tests');
    await frames(tester, 2);
    expect(stop, findsOneWidget);
    final send = find.byTooltip(RegExp('^Send'));
    expect(send, findsOneWidget);

    await tester.tap(send);
    await frames(tester);
    expect(server.sessionWork.sent, isEmpty);
    expect(find.text('Queued (1st)'), findsOneWidget);
    expect(server.sessionWork.interrupts, isEmpty);
  });

  testWidgets('a stopped turn says "Stopped" under it', (tester) async {
    await pump(
      tester,
      size: desktop,
      messages: [
        TranscriptMessage(role: 'user', text: 'fix the parser', at: testTime),
      ],
    );
    await working(tester, AgentActivityStatus.working);
    await tester.tap(stop);
    await frames(tester);
    await working(tester, AgentActivityStatus.idle);

    expect(find.textContaining('Stopped after'), findsOneWidget);
  });

  testWidgets('a turn still running after the grace offers to end the '
      'session, and a second Esc asks before it does', (tester) async {
    await pump(tester, size: desktop);
    await working(tester, AgentActivityStatus.working);
    await tester.tap(stop);
    await frames(tester);
    final line = find.text('Still working: press again to end the session');
    expect(line, findsNothing);

    await tester.pump(kStopEscalationAfter);
    await frames(tester);
    expect(line, findsOneWidget);
    expect(server.sessionWork.interrupts, ['acp-1']);

    await tester.tap(find.byType(TextField).last);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await frames(tester);
    // Asked, not ended: the confirm names it, and nothing more was stopped.
    expect(find.text('End session'), findsOneWidget);
    expect(server.sessionWork.interrupts, ['acp-1']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a turn that ends within the grace offers nothing more', (
    tester,
  ) async {
    await pump(tester, size: desktop);
    await working(tester, AgentActivityStatus.working);
    await tester.tap(stop);
    await frames(tester);
    await working(tester, AgentActivityStatus.idle);

    await tester.pump(kStopEscalationAfter);
    await frames(tester);
    expect(
      find.text('Still working: press again to end the session'),
      findsNothing,
    );
  });

  testWidgets('at 390 px and text scale 1.6 the escalation fits', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pump(tester, size: phone, touch: true);
    expect(tester.takeException(), isNull, reason: 'idle');
    await working(tester, AgentActivityStatus.working);
    expect(tester.takeException(), isNull, reason: 'working');
    await tester.tap(stop);
    await frames(tester);
    await tester.pump(kStopEscalationAfter);
    await frames(tester);
    expect(
      find.text('Still working: press again to end the session'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final (name, size, touch) in [
    ('phone', phone, true),
    ('desktop', desktop, false),
  ]) {
    testWidgets('on a $name, a "working" read off the screen offers Send '
        'beside Stop with the box empty; one the agent said offers Stop '
        'alone', (tester) async {
      await pump(tester, size: size, touch: touch);
      final send = find.byTooltip(RegExp('^Send'));

      statuses.add(
        AgentStatusReport(
          agentId: AgentIds.claudeAcp,
          sessionId: 'acp-1',
          status: AgentActivityStatus.working,
          observedAt: testTime,
          source: AgentStatusSource.terminalGrid,
        ),
      );
      await frames(tester);
      expect(stop, findsOneWidget);
      expect(send, findsOneWidget);
      expect(tester.takeException(), isNull);

      await working(tester, AgentActivityStatus.working);
      expect(stop, findsOneWidget);
      expect(send, findsNothing);
    });
  }
}
