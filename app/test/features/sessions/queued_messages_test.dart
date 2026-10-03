import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/presentation/usage_chip.dart'
    show formatResetClock;
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// **A message sent while the agent works is queued at the server**: it
/// shows below the transcript as a queued bubble with Edit and Cancel, the
/// composer stays free, and it leaves when the server delivers it. A server
/// without `sessions.queue` is never asked for one.
void main() {
  late TestMachine db;
  late FakeDataServer server;

  const phone = Size(390, 844);
  const desktop = Size(1440, 900);

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
  });

  Future<void> pump(
    WidgetTester tester, {
    required Size size,
    bool queues = true,
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
          ServerOffer(
            sameMachine: true,
            serverOs: 'windows',
            features: {
              'sessions.send',
              'sessions.interrupt',
              'sessions.send.resumes',
              if (queues) 'sessions.queue',
              if (queues) 'sessions.queue.control',
            },
          ),
        ),
        sessionRunningOnHostProvider.overrideWithValue((_) => true),
        sessionChatTranscriptProvider.overrideWith(
          (ref, id) => Stream.value(const <TranscriptMessage>[]),
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
        child: const MaterialApp(
          home: Scaffold(body: SessionTranscriptView(sessionId: 'acp-1')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).last, text);
    await tester.pump();
    await tester.tap(find.byTooltip(RegExp('^Send')));
    await tester.pumpAndSettle();
  }

  for (final (name, size) in [('phone', phone), ('desktop', desktop)]) {
    testWidgets('on a $name, a send mid-turn shows queued with Edit and '
        'Cancel, and the composer stays free', (tester) async {
      await pump(tester, size: size);

      await send(tester, 'then run the tests');

      expect(server.sessionWork.sent, isEmpty);
      expect(find.text('Queued · next'), findsOneWidget);
      expect(find.text('then run the tests'), findsOneWidget);
      expect(find.byKey(const ValueKey('queued-edit-q1')), findsOneWidget);
      expect(find.byKey(const ValueKey('queued-cancel-q1')), findsOneWidget);
      final composer = tester.widget<TextField>(find.byType(TextField).last);
      expect(composer.controller?.text, isEmpty);
      expect(composer.enabled ?? true, isTrue);

      await send(tester, 'and lint');
      expect(find.text('Queued · 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final (name, size) in [('phone', phone), ('desktop', desktop)]) {
    testWidgets('on a $name, a queue held on the usage limit says until '
        'when', (tester) async {
      await pump(tester, size: size);
      await send(tester, 'then run the tests');

      final until = testTime.add(const Duration(hours: 2));
      server.sessionWork.holdQueue(
        'acp-1',
        QueueHold(QueueHoldKind.limit, until: until),
      );
      await tester.pumpAndSettle();

      final clock = formatResetClock(until, testTime.toLocal());
      expect(find.text('Held until the limit resets · $clock'), findsOneWidget);
      expect(find.text('Queued · next'), findsOneWidget);

      server.sessionWork.holdQueue('acp-1', null);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('queue-hold')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final (name, size) in [('phone', phone), ('desktop', desktop)]) {
    testWidgets('on a $name, a queue paused by Stop offers Send next and '
        'Cancel all', (tester) async {
      await pump(tester, size: size);
      await send(tester, 'first');
      await send(tester, 'second');
      server.sessionWork.holdQueue(
        'acp-1',
        const QueueHold(QueueHoldKind.paused),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Paused'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('queue-send-next')));
      await tester.pumpAndSettle();
      expect(server.sessionWork.sent.map((s) => s.text), ['first']);
      expect(find.text('second'), findsOneWidget);
      expect(find.textContaining('Paused'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('queue-cancel-all')));
      await tester.pumpAndSettle();
      expect(server.sessionWork.queues['acp-1'], isEmpty);
      expect(find.byKey(const ValueKey('queue-hold')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final (name, size) in [('phone', phone), ('desktop', desktop)]) {
    testWidgets('on a $name, messages for a session nothing runs say so and '
        'offer Resume now', (tester) async {
      await pump(tester, size: size);
      await send(tester, 'first');
      server.sessionWork.holdQueue(
        'acp-1',
        const QueueHold(QueueHoldKind.stopped),
      );
      await tester.pumpAndSettle();

      expect(find.text("Waiting — this session isn't running"), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('queue-resume-now')));
      await tester.pumpAndSettle();
      expect(server.sessionWork.sent.map((s) => s.text), ['first']);
      expect(find.byKey(const ValueKey('queue-hold')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Edit replaces the queued text at the server', (tester) async {
    await pump(tester, size: phone);
    await send(tester, 'run the tests');

    await tester.tap(find.byKey(const ValueKey('queued-edit-q1')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('queued-edit-field')),
      'run the unit tests',
    );
    await tester.tap(find.byKey(const ValueKey('queued-edit-save')));
    await tester.pumpAndSettle();

    expect(
      server.sessionWork.queues['acp-1']!.single.text,
      'run the unit tests',
    );
    expect(find.text('run the unit tests'), findsOneWidget);
  });

  testWidgets('Cancel takes it off the queue', (tester) async {
    await pump(tester, size: desktop);
    await send(tester, 'run the tests');

    await tester.tap(find.byKey(const ValueKey('queued-cancel-q1')));
    await tester.pumpAndSettle();

    expect(server.sessionWork.queues['acp-1'], isEmpty);
    expect(find.text('Queued · next'), findsNothing);
    expect(
      server.sessionWork.queueAsked.whereType<SessionQueueCancel>(),
      hasLength(1),
    );
  });

  testWidgets('a delivered message leaves the queue; the next moves up', (
    tester,
  ) async {
    await pump(tester, size: desktop);
    await send(tester, 'first');
    await send(tester, 'second');

    server.sessionWork.deliverHead('acp-1');
    await tester.pumpAndSettle();

    expect(server.sessionWork.sent.map((s) => s.text), ['first']);
    expect(find.text('first'), findsNothing);
    expect(find.text('second'), findsOneWidget);
    expect(find.text('Queued · next'), findsOneWidget);
  });

  testWidgets('a server without sessions.queue is never asked for one', (
    tester,
  ) async {
    server.sessionWork.busy.clear();
    await pump(tester, size: phone, queues: false);

    await send(tester, 'hello');

    expect(server.sessionWork.sent.map((s) => s.text), ['hello']);
    expect(server.sessionWork.queueAsked, isEmpty);
    expect(find.textContaining('Queued'), findsNothing);
  });
}
