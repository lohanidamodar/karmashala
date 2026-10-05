import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/acp/acp_runtime_host.dart';
import 'package:karmashala_host/src/sessions/session_input.dart';
import 'package:karmashala_host/src/sessions/session_queue.dart';
import 'package:karmashala_host/src/status/daemon_agent_status.dart';
import 'package:karmashala_host/src/status/daemon_prompt_answers.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import '../acp/acp_fixture.dart';

/// A message sent while a session's turn runs waits at the server and is
/// delivered one per turn, in order; a queued one may be edited or
/// cancelled; a delivery a stop interrupted is failed, never resent.
void main() {
  final t0 = DateTime.utc(2026, 10, 3, 12);

  late AppDatabase database;
  late SessionRegistry registry;
  late FakePtyLauncher launcher;
  late DaemonAgentStatus status;
  late SessionQueueDao dao;
  late List<List<QueuedMessage>> announced;

  void insertSession(String id, String installation) =>
      SessionDao(database).insert(
        Session(
          id: id,
          repositoryId: 'r1',
          agentInstallationId: installation,
          title: 'Fix the cart',
          useWorktree: false,
          status: SessionStatus.running,
          createdAt: t0,
        ),
      );

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    database.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?);',
      ['r1', 'p1', 'shop-api', 'local', '/src/shop/api', t0.toIso8601String()],
    );
    for (final (id, kind) in [
      ('a1', AgentIds.claudeCode),
      ('a2', AgentIds.claudeAcp),
    ]) {
      database.execute(
        'INSERT INTO agent_installations (id, agent_kind, environment_id, '
        'executable_path, created_at, executable_by_user) '
        'VALUES (?, ?, ?, ?, ?, ?);',
        [id, kind, 'local', '/bin/$id', '$t0', 1],
      );
    }
    insertSession('s1', 'a1');
    insertSession('s2', 'a2');
    launcher = FakePtyLauncher();
    registry = SessionRegistry(launcher: launcher);
    status = DaemonAgentStatus(
      registry: registry,
      database: database,
      publish: (_, _) {},
      interval: const Duration(hours: 1),
    );
    dao = SessionQueueDao(database);
    announced = [];
  });

  tearDown(() async {
    await status.close();
    for (final handle in launcher.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    database.close();
  });

  SessionQueue queueOver({
    Duration grace = const Duration(seconds: 30),
    bool Function(String)? resumesOnSend,
    Duration quiet = const Duration(seconds: 30),
    Duration staleSweep = const Duration(seconds: 30),
    DateTime Function()? now,
    void Function(String message)? log,
    bool Function(String)? takesInputMidTurn,
  }) {
    var n = 0;
    final queue = SessionQueue(
      dao: dao,
      status: status,
      resumesOnSend: resumesOnSend,
      takesInputMidTurn: takesInputMidTurn,
      announce: (_, open) => announced.add(open),
      turnStartGrace: grace,
      quietPeriod: quiet,
      quietPoll: const Duration(milliseconds: 10),
      staleSweep: staleSweep,
      log: log,
      newId: () => 'q${++n}',
      now: now ?? () => t0,
    );
    addTearDown(queue.close);
    return queue;
  }

  group('a PTY session', () {
    late List<String> delivered;
    late SessionQueue queue;

    Future<void> runAgent() async {
      final text = File(
        '../app/test/features/agents/fixtures/claude-code-tui.raw',
      ).readAsStringSync();
      final teardown = text.indexOf('Session terminated');
      registry.open(
        'karmashala_s1',
        PtySpawnRequest(
          argv: const ['claude'],
          workingDirectory: '/src/shop/api',
          environment: const {},
          columns: 120,
          rows: 30,
        ),
      );
      launcher.handles.last.emit(
        utf8.encode(teardown < 0 ? text : text.substring(0, teardown)),
      );
      await pumpEventQueue();
      status.tick();
    }

    void hook(String event, {Map<String, Object?> extra = const {}}) =>
        status.hook(
          AgentHookEvent(
            agent: AgentIds.claudeCode,
            event: event,
            sessionHeader: 's1',
            receivedAt: DateTime.now().toUtc(),
            body: {'session_id': 'conv-1', 'hook_event_name': event, ...extra},
          ),
        );

    /// A `Stop` listing a watcher that is still running, as Claude Code
    /// sends it when its turn ends with background work going.
    void stopOverBackground() => hook(
      'Stop',
      extra: {
        'background_tasks': [
          {'type': 'shell', 'description': 'watch the build'},
        ],
      },
    );

    QueueAdmission send(String text, {String? requestId}) => queue.admit(
      's1',
      text,
      origin: QueuedMessageOrigin.app,
      requestId: requestId,
    );

    setUp(() {
      delivered = [];
      queue = queueOver()
        ..deliver = ((_, text) async => delivered.add(text))
        ..start();
    });

    test('an idle session takes a message at once; one sent while that is '
        'on its way waits', () async {
      await runAgent();
      expect(queue.busy('s1'), isFalse);
      expect(send('first'), isA<AdmitNow>());
      final second = send('second');
      expect(second, isA<AdmitQueued>());
      expect((second as AdmitQueued).position, 1);
      queue.afterImmediate('s1', delivered: true);
      await pumpEventQueue();
      expect(delivered, isEmpty, reason: 'the first turn has not been seen');
      hook('UserPromptSubmit');
      hook('Stop');
      await pumpEventQueue();
      expect(delivered, ['second']);
    });

    test('a held session queues every send and delivers once let go', () async {
      await runAgent();
      queue.hold('s1');
      expect(queue.busy('s1'), isTrue);
      expect(send('while switching'), isA<AdmitQueued>());
      await pumpEventQueue();
      expect(delivered, isEmpty);

      queue.release('s1');
      await pumpEventQueue();
      expect(delivered, ['while switching']);
    });

    test('messages sent mid-turn go one per turn, in order', () async {
      await runAgent();
      hook('UserPromptSubmit');
      expect(queue.busy('s1'), isTrue);
      final a = send('a') as AdmitQueued;
      final b = send('b') as AdmitQueued;
      expect((a.position, b.position), (1, 2));
      expect(announced.last.map((m) => m.text), ['a', 'b']);

      hook('Stop');
      await pumpEventQueue();
      expect(delivered, ['a']);
      expect(dao.getById(a.message.id)!.state, QueuedMessageState.delivered);
      // Still idle on screen: the turn "a" opens has not shown yet.
      hook('Stop');
      await pumpEventQueue();
      expect(delivered, ['a']);

      hook('UserPromptSubmit');
      hook('Stop');
      await pumpEventQueue();
      expect(delivered, ['a', 'b']);
      expect(announced.last, isEmpty);
    });

    group('typed in mid-turn', () {
      QueueAdmission typed(String text) => queue.admit(
        's1',
        text,
        origin: QueuedMessageOrigin.device,
        asTyping: true,
      );

      Future<void> overAgent({required bool takesInputMidTurn}) async {
        await queue.close();
        queue = queueOver(takesInputMidTurn: (_) => takesInputMidTurn)
          ..deliver = ((_, text) async => delivered.add(text))
          ..start();
        await runAgent();
        hook('UserPromptSubmit');
        expect(queue.busy('s1'), isTrue);
      }

      test('an agent that takes input mid-turn is given the message at '
          'once, and its turn\'s end sends nothing more', () async {
        await overAgent(takesInputMidTurn: true);
        final admission = typed('yes continue fixing');
        expect(admission, isA<AdmitNow>());
        expect((admission as AdmitNow).midTurn, isTrue);
        expect(dao.open('s1'), isEmpty);
        queue.afterImmediate('s1', delivered: true, midTurn: true);
        expect(queue.busy('s1'), isTrue, reason: 'its own turn still runs');

        hook('Stop');
        await pumpEventQueue();
        expect(queue.busy('s1'), isFalse);
        expect(typed('next'), isA<AdmitNow>());
      });

      test('one that does not is queued for its turn\'s end', () async {
        await overAgent(takesInputMidTurn: false);
        final admission = typed('yes continue fixing');
        expect(admission, isA<AdmitQueued>());
        hook('Stop');
        await pumpEventQueue();
        expect(delivered, ['yes continue fixing']);
      });

      test('a message still waits behind earlier ones, and a paused queue '
          'holds it', () async {
        await overAgent(takesInputMidTurn: true);
        expect(send('queued first'), isA<AdmitQueued>());
        expect(typed('behind it'), isA<AdmitQueued>());
        queue.setPaused('s1', paused: true);
        hook('Stop');
        await pumpEventQueue();
        expect(delivered, isEmpty);
        hook('UserPromptSubmit');
        expect(typed('while paused'), isA<AdmitQueued>());
      });

      test('an ordinary send is not typed in mid-turn', () async {
        await overAgent(takesInputMidTurn: true);
        expect(send('from an agent'), isA<AdmitQueued>());
      });

      /// A composer that shows what was typed until Return lets it go,
      /// or never takes the keys when [typeable] is false.
      SessionInput inputOver({required bool typeable, List<String>? typed}) {
        var field = '';
        final input = SessionInput(
          prompts: DaemonPromptAnswers(status: status, database: database),
          typist: SessionMessageTypist(
            poll: const Duration(milliseconds: 5),
            readScreen: (_) => ['> $field'],
            markersFor: (_) => const ['>'],
            type: (_, text) {
              if (!typeable) return false;
              field = text;
              return true;
            },
            press: (_, _) {
              typed?.add(field);
              field = '';
              return true;
            },
          ),
          queue: queue,
        );
        // What the queue delivers later is recorded, not typed.
        queue.deliver = (_, text) async => delivered.add(text);
        return input;
      }

      test('a phone message to a busy session is typed in and read back '
          'off the screen', () async {
        await overAgent(takesInputMidTurn: true);
        final typed = <String>[];
        final input = inputOver(typeable: true, typed: typed);
        final sent =
            await input.handle(
                  const SessionSend(sessionId: 's1', text: 'yes continue'),
                  'phone',
                )
                as SessionSent;
        expect(sent.queued, isFalse);
        expect(sent.via, SessionSent.readBack);
        expect(typed, ['yes continue']);
        expect(dao.open('s1'), isEmpty);
      });

      test('one the screen could not take falls back to the queue', () async {
        await overAgent(takesInputMidTurn: true);
        final input = inputOver(typeable: false);
        final sent =
            await input.handle(
                  const SessionSend(sessionId: 's1', text: 'yes continue'),
                  'phone',
                )
                as SessionSent;
        expect((sent.queued, sent.position), (true, 1));
        expect(dao.open('s1').single.origin, QueuedMessageOrigin.device);

        hook('Stop');
        await pumpEventQueue();
        expect(delivered, ['yes continue']);
      });
    });

    test('a turn that ends with background work running still delivers '
        'what waits, one per turn', () async {
      await runAgent();
      hook('UserPromptSubmit');
      final queued = [
        for (final text in ['one', 'two', 'three']) send(text) as AdmitQueued,
      ];
      expect(queued.map((q) => q.position), [1, 2, 3]);

      stopOverBackground();
      await pumpEventQueue();
      expect(
        status.statusOf('s1')!.report.status,
        AgentActivityStatus.working,
        reason: 'the session still reads working for its background run',
      );
      expect(delivered, ['one']);

      hook('UserPromptSubmit');
      expect(queue.busy('s1'), isTrue);
      stopOverBackground();
      await pumpEventQueue();
      expect(delivered, ['one', 'two']);

      hook('UserPromptSubmit');
      stopOverBackground();
      // Claude Code's idle nudge, while the run is still listed.
      hook('Notification', extra: {'notification_type': 'idle_prompt'});
      await pumpEventQueue();
      expect(delivered, ['one', 'two', 'three']);
      expect(announced.last, isEmpty);
    });

    test('a message left waiting behind a session at its prompt is logged '
        'and delivered', () async {
      await runAgent();
      hook('UserPromptSubmit');
      hook('Stop');
      await queue.close();
      final lines = <String>[];
      var clock = t0;
      queue = queueOver(
        staleSweep: const Duration(milliseconds: 20),
        now: () => clock,
        log: lines.add,
      )..deliver = ((_, text) async => delivered.add(text));
      queue.start();
      // Queued with no turn's end to come: nothing else would wake it.
      dao.enqueue(
        id: 'lost',
        sessionId: 's1',
        text: 'from the phone',
        origin: QueuedMessageOrigin.device,
        now: t0,
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(delivered, isEmpty, reason: 'not yet stale');

      clock = t0.add(const Duration(minutes: 5));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await pumpEventQueue();
      expect(delivered, ['from the phone']);
      expect(
        lines.where((l) => l.contains('lost') && l.contains('waited')),
        hasLength(1),
      );
    });

    test('Send now delivers the one named at once, mid-turn, and the rest '
        'keep their order', () async {
      await runAgent();
      hook('UserPromptSubmit');
      final ids = [
        for (final text in ['a', 'b', 'c'])
          (send(text) as AdmitQueued).message.id,
      ];

      final sent = await queue.sendNow('s1', ids[2]);
      expect(sent.state, QueuedMessageState.delivered);
      expect(delivered, ['c']);
      expect(queue.list('s1').map((m) => m.text), ['a', 'b']);

      hook('UserPromptSubmit');
      hook('Stop');
      await pumpEventQueue();
      expect(delivered, ['c', 'a']);
    });

    test('Send now refuses a message no longer waiting', () async {
      await runAgent();
      hook('UserPromptSubmit');
      final a = send('a') as AdmitQueued;
      queue.cancel('s1', a.message.id);
      await expectLater(
        queue.sendNow('s1', a.message.id),
        throwsA(
          isA<DataRefused>().having(
            (r) => r.code,
            'code',
            DataRefusalCode.conflict,
          ),
        ),
      );
      expect(delivered, isEmpty);
    });

    test(
      'Send all now delivers every waiting message together, as one',
      () async {
        await runAgent();
        hook('UserPromptSubmit');
        final queued = [
          for (final text in ['a', 'b', 'c']) send(text) as AdmitQueued,
        ];

        final sent = await queue.sendAll('s1');
        expect(delivered, ['a\n\nb\n\nc']);
        expect(
          sent.map((m) => m.state),
          everyElement(QueuedMessageState.delivered),
        );
        for (final q in queued) {
          expect(
            dao.getById(q.message.id)!.state,
            QueuedMessageState.delivered,
          );
        }
        expect(announced.last, isEmpty);
      },
    );

    test(
      'Pause holds the queue past the turn\'s end; resuming delivers',
      () async {
        await runAgent();
        hook('UserPromptSubmit');
        send('a');

        final paused = queue.setPaused('s1', paused: true);
        expect(paused.single.hold?.kind, QueueHoldKind.paused);
        hook('Stop');
        await pumpEventQueue();
        expect(delivered, isEmpty);

        final resumed = queue.setPaused('s1', paused: false);
        expect(resumed.single.hold, isNull);
        await pumpEventQueue();
        expect(delivered, ['a']);
      },
    );

    test('a turn never seen to start lets the next go after the grace', () {
      return runAgent().then((_) async {
        await queue.close();
        queue = queueOver(grace: const Duration(milliseconds: 30))
          ..deliver = ((_, text) async => delivered.add(text))
          ..start();
        hook('UserPromptSubmit');
        send('a');
        send('b');
        hook('Stop');
        await pumpEventQueue();
        expect(delivered, ['a']);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        await pumpEventQueue();
        expect(delivered, ['a', 'b']);
      });
    });

    group('a reader that drops to unknown mid-turn', () {
      const quiet = Duration(milliseconds: 300);

      void unknown() => status.report(
        's1',
        AgentStatusReport(
          agentId: AgentIds.claudeCode,
          sessionId: 'conv-1',
          status: AgentActivityStatus.unknown,
          observedAt: DateTime.now().toUtc(),
          source: AgentStatusSource.terminalGrid,
        ),
      );

      /// The agent keeps streaming: [count] screen updates [every] apart.
      Future<void> streams(int count, Duration every) async {
        for (var i = 0; i < count; i++) {
          launcher.handles.last.emit(utf8.encode('word $i of the essay\r\n'));
          await Future<void>.delayed(every);
        }
      }

      setUp(() async {
        await queue.close();
        queue = queueOver(quiet: quiet)
          ..deliver = ((_, text) async => delivered.add(text))
          ..start();
      });

      test('keeps the message queued while the screen still moves', () async {
        await runAgent();
        hook('UserPromptSubmit');
        expect(send('a'), isA<AdmitQueued>());
        unknown();
        expect(
          status.statusOf('s1')!.report.status,
          AgentActivityStatus.unknown,
        );
        expect(queue.busy('s1'), isTrue, reason: 'still mid-turn');
        expect(send('b'), isA<AdmitQueued>());

        await streams(12, const Duration(milliseconds: 30));
        expect(delivered, isEmpty);
      });

      test('delivers once the screen has been quiet for the period', () async {
        await runAgent();
        hook('UserPromptSubmit');
        send('a');
        unknown();
        await streams(4, const Duration(milliseconds: 30));
        expect(delivered, isEmpty);

        await Future<void>.delayed(quiet * 3);
        await pumpEventQueue();
        expect(delivered, ['a']);
      });

      test('idle after working delivers at once', () async {
        await runAgent();
        hook('UserPromptSubmit');
        send('a');
        unknown();
        hook('Stop');
        await pumpEventQueue();
        expect(delivered, ['a']);
      });
    });

    test('a resend with the same requestId is answered with its row', () async {
      await runAgent();
      hook('UserPromptSubmit');
      final first = send('a', requestId: 'r1') as AdmitQueued;
      final again = send('a', requestId: 'r1') as AdmitQueued;
      expect(again.message.id, first.message.id);
      expect(dao.open('s1'), hasLength(1));
    });

    test('only a queued message is edited or cancelled', () async {
      await runAgent();
      hook('UserPromptSubmit');
      final a = (send('a') as AdmitQueued).message;
      final b = (send('b') as AdmitQueued).message;
      expect(queue.edit('s1', a.id, 'a, but sooner').text, 'a, but sooner');
      expect(() => queue.edit('s1', a.id, '  '), throwsA(isA<DataRefused>()));
      expect(
        () => queue.edit('s2', a.id, 'x'),
        throwsA(
          isA<DataRefused>().having(
            (r) => r.code,
            'code',
            DataRefusalCode.notFound,
          ),
        ),
      );
      expect(queue.cancel('s1', b.id).state, QueuedMessageState.cancelled);
      expect(
        () => queue.cancel('s1', b.id),
        throwsA(
          isA<DataRefused>().having(
            (r) => r.code,
            'code',
            DataRefusalCode.conflict,
          ),
        ),
      );

      final release = Completer<void>();
      queue.deliver = (_, text) async {
        await release.future;
        delivered.add(text);
      };
      hook('Stop');
      await pumpEventQueue();
      expect(dao.getById(a.id)!.state, QueuedMessageState.delivering);
      expect(
        () => queue.edit('s1', a.id, 'too late'),
        throwsA(
          isA<DataRefused>().having(
            (r) => r.message,
            'message',
            contains('being delivered'),
          ),
        ),
      );
      expect(() => queue.cancel('s1', a.id), throwsA(isA<DataRefused>()));
      release.complete();
      await pumpEventQueue();
      expect(delivered, ['a, but sooner']);
      expect(queue.list('s1'), isEmpty);
    });

    test('a refusal that typed nothing holds the message; one that may have '
        'typed fails it', () async {
      await runAgent();
      hook('UserPromptSubmit');
      final a = (send('a') as AdmitQueued).message;
      queue.deliver = (_, _) async =>
          throw const DataRefused.notFound('this session is not running here');
      hook('Stop');
      await pumpEventQueue();
      expect(dao.getById(a.id)!.state, QueuedMessageState.queued);

      queue.deliver = (_, _) async => throw const DataRefused(
        DataRefusalCode.failed,
        'the agent did not take the Return',
      );
      // Held until the next turn's end.
      hook('UserPromptSubmit');
      hook('Stop');
      await pumpEventQueue();
      final failed = dao.getById(a.id)!;
      expect(failed.state, QueuedMessageState.failed);
      expect(failed.error, contains('Return'));
      expect(await queue.settled(a.id), failed);
      expect(queue.cancel('s1', a.id).state, QueuedMessageState.cancelled);
    });

    test('a stopped session holds its queue rather than refusing or '
        'relaunching', () async {
      dao.enqueue(
        id: 'old',
        sessionId: 's1',
        text: 'earlier',
        origin: QueuedMessageOrigin.app,
        now: t0,
      );
      expect(send('later'), isA<AdmitQueued>());
      await pumpEventQueue();
      expect(delivered, isEmpty);
      expect(queue.list('s1').map((m) => m.text), ['earlier', 'later']);

      await runAgent();
      hook('Stop');
      await pumpEventQueue();
      expect(delivered, ['earlier']);
    });

    test('a delivery a stopped server left is failed at boot and never '
        'resent', () async {
      final left = dao.enqueue(
        id: 'left',
        sessionId: 's1',
        text: 'mid-flight',
        origin: QueuedMessageOrigin.app,
        now: t0,
      );
      dao.transition(
        left.id,
        from: QueuedMessageState.queued,
        to: QueuedMessageState.delivering,
        now: t0,
      );
      await queue.close();
      final rebooted = queueOver()
        ..deliver = ((_, text) async => delivered.add(text))
        ..start();
      final failed = dao.getById('left')!;
      expect(failed.state, QueuedMessageState.failed);
      expect(failed.error, SessionQueue.interruptedError);
      expect(announced.last.single.id, 'left');

      await runAgent();
      hook('Stop');
      await pumpEventQueue();
      expect(delivered, isEmpty);
      expect(rebooted.busy('s1'), isFalse);
    });
  });

  test('a send to a stopped ACP session with messages waiting hands the '
      'head to the delivery that resumes it', () async {
    final delivered = <String>[];
    final queue = queueOver(resumesOnSend: (id) => id == 's2')
      ..deliver = ((_, text) async => delivered.add(text))
      ..start();
    dao.enqueue(
      id: 'old',
      sessionId: 's2',
      text: 'earlier',
      origin: QueuedMessageOrigin.app,
      now: t0,
    );

    expect(
      queue.admit('s2', 'later', origin: QueuedMessageOrigin.app),
      isA<AdmitQueued>(),
    );
    await pumpEventQueue();

    expect(delivered, ['earlier']);
    expect(dao.getById('old')!.state, QueuedMessageState.delivered);
  });

  group('an ACP session, through SessionInput', () {
    late DaemonPromptAnswers prompts;
    late Directory temp;

    setUp(() {
      prompts = DaemonPromptAnswers(status: status, database: database);
      temp = Directory.systemTemp.createTempSync('session_queue_test');
    });
    tearDown(() => temp.deleteSync(recursive: true));

    test('Send now mid-turn is refused in words, and the message goes '
        'next', () async {
      final process = FakeAcpProcess(
        FakeAcpAgent(
          turns: const [
            FakeTurn([FakeStep.message('on it'), FakeStep.waitForCancel()]),
          ],
        ),
      );
      final runtime = registry.openAcp(
        'karmashala_s2',
        runtimeOver(
          process,
          database: database,
          workingDirectory: temp.path,
          sessionId: 's2',
          host: _DaemonHost(status),
        ),
      );
      await runtime.start();
      status.tick();
      final queue = queueOver()..start();
      final input = SessionInput(
        prompts: prompts,
        typist: SessionMessageTypist(
          readScreen: (_) => null,
          markersFor: (_) => null,
          type: (_, _) => false,
          press: (_, _) => false,
        ),
        queue: queue,
      );
      await input.handle(
        const SessionSend(sessionId: 's2', text: 'First'),
        null,
      );
      await pump();
      await input.handle(
        const SessionSend(sessionId: 's2', text: 'Second'),
        null,
      );
      final third =
          await input.handle(
                const SessionSend(sessionId: 's2', text: 'Third'),
                null,
              )
              as SessionSent;

      await expectLater(
        input.handle(
          SessionQueueSendNow(sessionId: 's2', id: third.queuedId!),
          null,
        ),
        throwsA(
          isA<DataRefused>().having(
            (r) => r.message,
            'message',
            contains('goes next'),
          ),
        ),
      );
      expect(queue.list('s2').map((m) => m.text), ['Third', 'Second']);
      expect(process.agent.prompts, hasLength(1));
    });

    test('a send mid-turn is queued and goes as the next prompt when the '
        'turn ends, one per turn', () async {
      final process = FakeAcpProcess(
        FakeAcpAgent(
          turns: const [
            FakeTurn([FakeStep.message('on it'), FakeStep.waitForCancel()]),
            FakeTurn([FakeStep.message('second done')]),
            FakeTurn([FakeStep.message('third done')]),
          ],
        ),
      );
      final runtime = registry.openAcp(
        'karmashala_s2',
        runtimeOver(
          process,
          database: database,
          workingDirectory: temp.path,
          sessionId: 's2',
          host: _DaemonHost(status),
        ),
      );
      await runtime.start();
      status.tick();
      final queue = queueOver()..start();
      final input = SessionInput(
        prompts: prompts,
        typist: SessionMessageTypist(
          readScreen: (_) => null,
          markersFor: (_) => null,
          type: (_, _) => false,
          press: (_, _) => false,
        ),
        queue: queue,
      );

      final first =
          await input.handle(
                const SessionSend(sessionId: 's2', text: 'First'),
                null,
              )
              as SessionSent;
      expect(first.via, SessionInput.viaProtocol);
      await pump();
      final second =
          await input.handle(
                const SessionSend(
                  sessionId: 's2',
                  text: 'Second',
                  requestId: 'r2',
                ),
                'phone',
              )
              as SessionSent;
      expect((second.queued, second.position), (true, 1));
      final third =
          await input.handle(
                const SessionSend(sessionId: 's2', text: 'Third'),
                null,
              )
              as SessionSent;
      expect(third.position, 2);
      final listed =
          await input.handle(const SessionQueueList('s2'), null)
              as List<QueuedMessage>;
      expect(listed.map((m) => (m.text, m.origin)), [
        ('Second', QueuedMessageOrigin.device),
        ('Third', QueuedMessageOrigin.app),
      ]);
      expect(listed.first.originId, 'phone');
      expect(process.agent.prompts, hasLength(1));

      runtime.cancel();
      await runtime.awaitTurn();
      await pump();
      expect(process.agent.prompts[1].single.toJson()['text'], 'Second');
      await runtime.awaitTurn();
      await pump();
      await runtime.awaitTurn();
      await pump();
      expect(process.agent.prompts, hasLength(3));
      final rows = SessionMessageDao(database).listAfter('s2');
      expect(rows.map((r) => r.text), [
        'First',
        'on it',
        'Second',
        'second done',
        'Third',
        'third done',
      ]);
      expect(await input.handle(const SessionQueueList('s2'), null), isEmpty);
    });
  });
}

/// The server's host for a runtime, cut to what these cases observe.
final class _DaemonHost extends AcpRuntimeHost {
  const _DaemonHost(this._status);

  final DaemonAgentStatus _status;

  @override
  void status(
    String sessionId,
    AgentStatusReport report, {
    AgentQuestionSet? question,
  }) => _status.report(sessionId, report);

  @override
  Future<void> checkpointSettled(String sessionId) async {}

  @override
  void checkpointTouched(String sessionId, Iterable<String> paths) {}

  @override
  void checkpointPrompt(String sessionId, String prompt) {}

  @override
  void modesChanged(SessionModesChanged change) {}

  @override
  void configOptionsChanged(SessionConfigOptionsChanged change) {}

  @override
  void usageChanged(SessionUsageChanged change) {}

  @override
  void messagesChanged(String sessionId) {}

  @override
  void log(String message) {}
}
