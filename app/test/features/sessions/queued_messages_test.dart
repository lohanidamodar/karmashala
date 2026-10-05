import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart'
    show
        BackgroundRun,
        BackgroundRunKind,
        BackgroundRunState,
        TranscriptMessage;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/presentation/usage_chip.dart'
    show formatResetClock;
import 'package:karmashala/src/features/sessions/application/background_runs_providers.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_activity_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/presentation/queued_messages_strip.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/sessions/presentation/transcript_image_preview.dart';
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

  // A running call ticks every second, so such a screen never settles.
  var ticking = false;
  Future<void> settle(WidgetTester tester) async {
    if (!ticking) {
      await tester.pumpAndSettle();
      return;
    }
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pump(
    WidgetTester tester, {
    required Size size,
    bool queues = true,
    SessionActivity? activity,
    bool withBar = false,
    int backgroundRuns = 0,
    double keyboard = 0,
    bool withAppBar = false,
  }) async {
    ticking = activity != null;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
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
              if (queues) 'sessions.queue.manage',
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
        if (activity != null)
          sessionOutstandingCallsProvider.overrideWith((ref, _) => activity),
        if (backgroundRuns > 0)
          sessionBackgroundRunsProvider.overrideWith(
            (ref, _) => [
              for (var i = 0; i < backgroundRuns; i++)
                SessionBackgroundRun(
                  run: BackgroundRun(
                    id: 'run-$i',
                    kind: BackgroundRunKind.command,
                    state: BackgroundRunState.running,
                    description: 'watch number $i',
                  ),
                  startedAt: testTime,
                ),
            ],
          ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            // The phone's top bar.
            appBar: withAppBar ? AppBar(title: const Text('Session')) : null,
            body: Column(
              children: [
                // The session bar's chip, as the terminal view shows it.
                if (withBar) const QueuedCountChip(sessionId: 'acp-1'),
                const Expanded(
                  child: SessionTranscriptView(sessionId: 'acp-1'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).last, text);
    await tester.pump();
    await tester.tap(find.byTooltip(RegExp('^Send')));
    await settle(tester);
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

  testWidgets('on a phone with the keyboard up, a queued message folds to '
      'one line that opens the queue, never an empty box', (tester) async {
    await pump(
      tester,
      size: phone,
      keyboard: 300,
      withAppBar: true,
      withBar: true,
      backgroundRuns: 1,
      activity: SessionActivity([
        OutstandingCall(
          summary: 'Bash(flutter test)',
          toolName: 'Bash',
          startedAt: testTime,
        ),
      ]),
    );
    await send(tester, 'yes continue fixing');

    expect(tester.takeException(), isNull);
    final line = find.text('1 queued · Sends when the agent finishes its turn');
    expect(line, findsOneWidget);
    final rect = tester.getRect(line);
    expect(rect.height, greaterThan(10));
    expect(rect.bottom, lessThanOrEqualTo(phone.height - 300));
    final strip = tester.getRect(find.byKey(const ValueKey('queued-strip')));
    expect(strip.height, greaterThanOrEqualTo(rect.height));

    await tester.tap(line);
    await settle(tester);
    expect(find.byKey(const ValueKey('queue-row-q1')), findsOneWidget);
  });

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

      final holdLine = find.descendant(
        of: find.byKey(const ValueKey('queue-hold')),
        matching: find.textContaining('Paused'),
      );
      expect(holdLine, findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('queue-send-next')));
      await tester.pumpAndSettle();
      expect(server.sessionWork.sent.map((s) => s.text), ['first']);
      expect(find.text('second'), findsOneWidget);
      expect(holdLine, findsOneWidget);

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

  for (final (name, size) in [('phone', phone), ('desktop', desktop)]) {
    testWidgets('on a $name, a session the person ended: Resume now refused '
        'says why and keeps the message waiting', (tester) async {
      await pump(tester, size: size);
      await send(tester, 'first');
      server.sessionWork
        ..running.remove('acp-1')
        ..sendNextRefusesWith = 'Codex would not start: log in first'
        ..holdQueue('acp-1', const QueueHold(QueueHoldKind.stopped));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('queue-resume-now')));
      await tester.pump();
      expect(
        find.text('Could not resume it: Codex would not start: log in first'),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      expect(server.sessionWork.sent, isEmpty);
      expect(find.text('first'), findsOneWidget);
      expect(find.byKey(const ValueKey('queue-resume-now')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final (name, size) in [('phone', phone), ('desktop', desktop)]) {
    testWidgets('on a $name, long queued messages are clamped to three lines '
        'and the running turn\'s Stop stays above the composer', (
      tester,
    ) async {
      await pump(
        tester,
        size: size,
        activity: SessionActivity([
          OutstandingCall(
            summary: 'Bash(flutter test)',
            toolName: 'Bash',
            startedAt: testTime,
          ),
        ]),
      );
      final long = [
        for (var i = 0; i < 30; i++) 'step $i of a long instruction',
      ].join('\n');
      await send(tester, long);
      await send(tester, long);
      await send(tester, long);

      expect(find.byKey(const ValueKey('queued-expand-q1')), findsOneWidget);
      final stop = find.byTooltip(RegExp('^Stop the running turn'));
      expect(stop, findsOneWidget);
      final composerTop = tester.getRect(find.byType(TextField).last).top;
      final stopRect = tester.getRect(stop);
      expect(stopRect.top, greaterThanOrEqualTo(0));
      expect(stopRect.bottom, lessThanOrEqualTo(composerTop));

      await tester.tap(find.byKey(const ValueKey('queued-expand-q1')));
      await settle(tester);
      expect(find.text('Show less'), findsOneWidget);
      expect(tester.getRect(stop).bottom, lessThanOrEqualTo(composerTop));
      expect(tester.takeException(), isNull);
    });
  }

  for (final (name, size) in [('phone', phone), ('desktop', desktop)]) {
    testWidgets('on a $name, Edit offers Cancel and Save, and Save is off '
        'while the text is empty', (tester) async {
      await pump(tester, size: size);
      await send(tester, 'run the tests');

      await tester.tap(find.byKey(const ValueKey('queued-edit-q1')));
      await tester.pumpAndSettle();
      expect(find.text('Keep it'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('queued-edit-field')),
        '   ',
      );
      await tester.pump();
      final save = tester.widget<FilledButton>(
        find.byKey(const ValueKey('queued-edit-save')),
      );
      expect(save.onPressed, isNull);

      await tester.tap(find.byKey(const ValueKey('queued-edit-cancel')));
      await tester.pumpAndSettle();
      expect(server.sessionWork.queues['acp-1']!.single.text, 'run the tests');
      expect(
        server.sessionWork.queueAsked.whereType<SessionQueueEdit>(),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('on a $name, a failed message goes back to the composer and '
        'is dismissed', (tester) async {
      await pump(tester, size: size);
      await send(tester, 'run the tests');
      final queue = server.sessionWork.queues['acp-1']!;
      queue[0] = queue[0].copyWith(
        state: QueuedMessageState.failed,
        error: 'the agent did not take the Return',
      );
      server.sessionWork.holdQueue('acp-1', null);
      await tester.pumpAndSettle();

      expect(find.text('Not sent'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('queued-back-q1')));
      await tester.pumpAndSettle();

      final composer = tester.widget<TextField>(find.byType(TextField).last);
      expect(composer.controller?.text, 'run the tests');
      expect(server.sessionWork.queues['acp-1'], isEmpty);
      expect(find.text('Not sent'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final (name, size) in [('phone', phone), ('desktop', desktop)]) {
    testWidgets('on a $name, the session bar counts what waits and says what '
        'holds it', (tester) async {
      await pump(tester, size: size, withBar: true);
      expect(find.byKey(const ValueKey('queued-count')), findsNothing);

      await send(tester, 'first');
      await send(tester, 'second');
      expect(find.text('2 queued'), findsOneWidget);

      server.sessionWork.holdQueue(
        'acp-1',
        const QueueHold(QueueHoldKind.paused),
      );
      await tester.pumpAndSettle();
      expect(find.text('Paused · 2'), findsOneWidget);
      expect(
        find.byTooltip(RegExp('^2 messages wait · Paused')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  /// Three queued messages of a few lines each, the composer's words.
  Future<void> queueThree(WidgetTester tester) async {
    for (final name in ['first', 'second', 'third']) {
      await send(
        tester,
        [for (var i = 0; i < 6; i++) '$name message, line $i'].join('\n'),
      );
    }
  }

  for (final (name, size) in [('phone', phone), ('desktop', desktop)]) {
    testWidgets('on a $name, with three queued and many background runs the '
        'strip is bounded, scrolls, and every card keeps Edit and Cancel in '
        'reach', (tester) async {
      await pump(tester, size: size, backgroundRuns: 12);
      await queueThree(tester);

      final strip = tester.getRect(find.byKey(const ValueKey('queued-strip')));
      expect(strip.height, lessThanOrEqualTo(size.height / 4 + 1));
      expect(
        find.text('Sends when the agent finishes its turn'),
        findsNWidgets(3),
      );
      final composerTop = tester.getRect(find.byType(TextField).last).top;
      for (final id in ['q1', 'q2', 'q3']) {
        for (final what in ['edit', 'cancel']) {
          final button = find.byKey(ValueKey('queued-$what-$id'));
          await tester.ensureVisible(button);
          await tester.pumpAndSettle();
          final rect = tester.getRect(button);
          expect(rect.top, greaterThanOrEqualTo(strip.top - 1), reason: id);
          expect(rect.bottom, lessThanOrEqualTo(strip.bottom + 1), reason: id);
          expect(rect.bottom, lessThanOrEqualTo(composerTop), reason: id);
          expect(button.hitTestable(), findsOneWidget, reason: '$what $id');
        }
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('on a $name, the queued chip opens the queue: every message '
        'in order, each with View, Edit, Remove and Send now', (tester) async {
      await pump(tester, size: size, withBar: true, backgroundRuns: 12);
      await queueThree(tester);
      expect(
        find.byTooltip(
          RegExp('^3 messages wait · Sends when the agent finishes its turn'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('queued-count')));
      await tester.pumpAndSettle();
      final rows = [
        for (final id in ['q1', 'q2', 'q3'])
          find.byKey(ValueKey('queue-row-$id')),
      ];
      for (final row in rows) {
        expect(row, findsOneWidget);
      }
      expect(
        tester.getRect(rows[0]).top,
        lessThan(tester.getRect(rows[1]).top),
      );
      expect(
        tester.getRect(rows[1]).top,
        lessThan(tester.getRect(rows[2]).top),
      );
      for (final id in ['q1', 'q2', 'q3']) {
        for (final what in ['view', 'edit', 'remove', 'send-now']) {
          expect(find.byKey(ValueKey('queue-$what-$id')), findsOneWidget);
        }
      }
      expect(find.byKey(const ValueKey('queue-send-all')), findsOneWidget);
      expect(find.byKey(const ValueKey('queue-pause')), findsOneWidget);

      await tester.ensureVisible(
        find.byKey(const ValueKey('queue-send-now-q3')),
      );
      await tester.tap(find.byKey(const ValueKey('queue-send-now-q3')));
      await tester.pumpAndSettle();
      expect(server.sessionWork.sent.single.text, startsWith('third message'));
      expect(find.byKey(const ValueKey('queue-row-q3')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('queue-remove-q1')));
      await tester.pumpAndSettle();
      expect(server.sessionWork.queues['acp-1']!.map((m) => m.id), ['q2']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the queue pauses and resumes, and Send all sends them '
      'together', (tester) async {
    await pump(tester, size: phone, withBar: true);
    await send(tester, 'first');
    await send(tester, 'second');

    await tester.tap(find.byKey(const ValueKey('queued-count')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('queue-pause')));
    await tester.pumpAndSettle();
    expect(server.sessionWork.holds['acp-1']?.kind, QueueHoldKind.paused);
    expect(find.byKey(const ValueKey('queue-resume')), findsOneWidget);
    expect(find.text('Paused: nothing goes until you resume'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('queue-resume')));
    await tester.pumpAndSettle();
    expect(server.sessionWork.holds['acp-1'], isNull);

    await tester.tap(find.byKey(const ValueKey('queue-send-all')));
    await tester.pumpAndSettle();
    expect(server.sessionWork.sent.map((s) => s.text), ['first\n\nsecond']);
    expect(server.sessionWork.queues['acp-1'], isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('View shows the whole text and the images a message carries', (
    tester,
  ) async {
    await pump(tester, size: phone, withBar: true);
    await send(
      tester,
      'look at this\n\nAttached image(s):\nC:\\shots\\screen.png',
    );

    await tester.tap(find.byKey(const ValueKey('queued-count')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('queue-view-q1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('queue-view-text')), findsOneWidget);
    expect(find.text('look at this'), findsWidgets);
    expect(
      find.byWidgetPredicate(
        (w) => w is TranscriptImagePreview && w.path == r'C:\shots\screen.png',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('each card says when it will go: held on the limit until when, '
      'or waiting on a stopped session', (tester) async {
    await pump(tester, size: phone);
    await send(tester, 'first');
    final until = testTime.add(const Duration(hours: 2));
    server.sessionWork.holdQueue(
      'acp-1',
      QueueHold(QueueHoldKind.limit, until: until),
    );
    await tester.pumpAndSettle();
    final clock = formatResetClock(until, testTime.toLocal());
    expect(find.text('Held: usage limit until $clock'), findsOneWidget);

    server.sessionWork.holdQueue(
      'acp-1',
      const QueueHold(QueueHoldKind.stopped),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Waiting: the session is stopped (resumes on send)'),
      findsOneWidget,
    );
  });

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
