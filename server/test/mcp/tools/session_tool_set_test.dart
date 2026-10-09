import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_host/data.dart' show DataService;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/mcp/tools/server_tool_context.dart';
import 'package:karmashala_host/src/mcp/tools/session_tool_set.dart';
import 'package:karmashala_host/src/sessions/session_input.dart';
import 'package:karmashala_host/src/sessions/session_queue.dart';
import 'package:karmashala_host/src/status/daemon_agent_status.dart';
import 'package:karmashala_host/src/status/daemon_prompt_answers.dart';
import 'package:karmashala_host/src/status/hosted_session_wait.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:agent_cli/stream.dart';

/// The session tools the server answers itself for a session it runs —
/// `session_send`, `session_wait`, `session_transcript`, `session_end`,
/// `session_rename`, `session_answer` — with no app, and what it hands the
/// app instead. Nothing is stubbed but the PTY, fed a real agent's bytes.
void main() {
  final t0 = DateTime.utc(2026, 9, 27, 12);

  late AppDatabase database;
  late SessionRegistry registry;
  late FakePtyLauncher launcher;
  late DaemonAgentStatus status;
  late DaemonPromptAnswers prompts;
  late ServerToolContext context;
  late Completer<void> deadline;
  late SessionToolSet tools;

  void insertSession(String id, {String title = 'Fix the cart'}) =>
      SessionDao(database).insert(
        Session(
          id: id,
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: title,
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
    database.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at, executable_by_user) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      ['a1', AgentIds.claudeCode, 'local', '/bin/claude', '$t0', 1],
    );
    insertSession('s1');
    insertSession('caller', title: 'Orchestrator');
    launcher = FakePtyLauncher();
    registry = SessionRegistry(launcher: launcher);
    status = DaemonAgentStatus(
      registry: registry,
      database: database,
      publish: (_, _) {},
      interval: const Duration(hours: 1),
    );
    prompts = DaemonPromptAnswers(
      status: status,
      database: database,
      menuPoll: const Duration(milliseconds: 5),
      menuPatience: const Duration(milliseconds: 300),
    );
    context = ServerToolContext(
      database: database,
      data: DataService(database, clock: () => t0),
      dataDirectory: '/nowhere',
      clock: () => t0,
    );
    deadline = Completer<void>();
    tools = SessionToolSet(
      context,
      prompts: prompts,
      registry: registry,
      waits: HostedSessionWait(
        status: status,
        deadline: (_) => deadline.future,
      ),
      typist: SessionToolSet.typistOver(
        prompts,
        poll: const Duration(milliseconds: 2),
        typedPatience: const Duration(milliseconds: 20),
        sendPatience: const Duration(milliseconds: 20),
      ),
    );
  });

  tearDown(() async {
    context.close();
    await status.close();
    for (final handle in launcher.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    database.close();
  });

  List<int> fixture(String name) {
    final text = File(
      '../app/test/features/agents/fixtures/$name.raw',
    ).readAsStringSync();
    final teardown = text.indexOf('Session terminated');
    return utf8.encode(teardown < 0 ? text : text.substring(0, teardown));
  }

  Future<FakePtyHandle> runAgent(String fixtureName) async {
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
    final agent = launcher.handles.last..emit(fixture(fixtureName));
    await pumpEventQueue();
    status.tick();
    return agent;
  }

  AgentHookEvent hook(String event) => AgentHookEvent(
    agent: AgentIds.claudeCode,
    event: event,
    sessionHeader: 's1',
    receivedAt: DateTime.now().toUtc(),
    body: {'session_id': 'conv-1', 'hook_event_name': event},
  );

  String typedInto(FakePtyHandle agent) =>
      [for (final write in agent.writes) utf8.decode(write)].join();

  Future<Map<String, Object?>> call(
    String tool,
    Map<String, Object?> arguments, {
    String? caller,
  }) async =>
      (await tools.call(tool, arguments, caller)!) as Map<String, Object?>;

  group('session_send', () {
    test('types into the session the host runs, under the sender\'s name, '
        'and records the relay', () async {
      final agent = await runAgent('claude-code-tui');
      final sent = await call('session_send', {
        'sessionId': 's1',
        'text': 'run the tests',
      }, caller: 'caller');

      expect(sent['delivered'], isTrue);
      expect(sent['live'], isTrue);
      expect(
        sent['attribution'],
        '[message from the Karmashala session "Orchestrator" (caller)]',
      );
      expect(
        typedInto(agent),
        startsWith(
          '[message from the Karmashala session "Orchestrator" (caller)]'
          '\n\nrun the tests',
        ),
      );
      expect(typedInto(agent), endsWith('\r'));
      final relays = context.write(const RelaysTo('s1', 5)).relays;
      expect(relays.single.fromSessionId, 'caller');
      expect(relays.single.text, 'run the tests');
    });

    test(
      'is refused, nothing typed, while an approval prompt is open',
      () async {
        final agent = await runAgent('claude-code-permission-modal');
        await expectLater(
          tools.call('session_send', {'sessionId': 's1', 'text': 'hi'}, null),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('approval prompt open'),
            ),
          ),
        );
        expect(agent.writes, isEmpty);
      },
    );

    test(
      'at Codex 0.160\'s folder-trust menu the session needs you: the '
      'send is refused and nothing is typed, so the agent is not quit',
      () async {
        // Typed into that menu, a `q` or a `2` in the message quits Codex
        // (measured on 0.160.0), which is how an agent-started session there
        // ended within seconds of a send.
        database.execute(
          "UPDATE agent_installations SET agent_kind = ? WHERE id = 'a1';",
          [AgentIds.codex],
        );
        final agent = await runAgent('codex-trust-prompt-0.160');
        final report = status.statusOf('s1')!.report;
        expect(report.status, AgentActivityStatus.awaitingApproval);
        expect(report.hasOpenPrompt, isTrue);

        await expectLater(
          tools.call('session_send', {
            'sessionId': 's1',
            'text': 'quick review, 2 files',
          }, 'caller'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('approval prompt open'),
            ),
          ),
        );
        expect(agent.writes, isEmpty);
        expect(agent.signals, isEmpty);
        expect(status.holds('s1'), isTrue);
      },
    );

    test('stops at the budget: twenty relays in ten minutes', () async {
      await runAgent('claude-code-tui');
      for (var i = 0; i < relayBudget; i++) {
        context.write(
          RelayRecord(
            SessionRelay(
              fromSessionId: 'caller',
              toSessionId: 's1',
              text: 'm$i',
              at: t0,
            ),
          ),
        );
      }
      await expectLater(
        tools.call('session_send', {
          'sessionId': 's1',
          'text': 'one more',
        }, 'caller'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            startsWith('NOTHING WAS SENT'),
          ),
        ),
      );
    });

    test('a session nothing runs is refused in words when it cannot be '
        'resumed, and nothing is handed to an app', () async {
      await expectLater(
        tools.call('session_send', {'sessionId': 's1', 'text': 'hi'}, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('open_session resumes it'),
          ),
        ),
      );
    });

    test('a session nothing runs is resumed with the message as its opening '
        'prompt, under the sender\'s name', () async {
      final resumed = <(String, String, TabReveal)>[];
      final resuming = SessionToolSet(
        context,
        prompts: prompts,
        registry: registry,
        resumeWith: (sessionId, prompt, reveal) async =>
            resumed.add((sessionId, prompt, reveal)),
      );
      final answer =
          await resuming.call('session_send', {
                'sessionId': 's1',
                'text': 'carry on',
              }, 'caller')!
              as Map<String, Object?>;
      expect(answer['delivered'], isTrue);
      expect(answer['resumed'], isTrue);
      expect(resumed.single.$1, 's1');
      expect(resumed.single.$2, contains('carry on'));
      expect(resumed.single.$2, contains('Orchestrator'));
      expect(
        resumed.single.$3,
        TabReveal.background,
        reason: 'another session resumed it, so it opens behind',
      );
    });

    test('to a session mid-turn is queued, not typed, and delivered under '
        'the sender\'s name when the turn ends', () async {
      final typist = SessionToolSet.typistOver(
        prompts,
        poll: const Duration(milliseconds: 2),
        typedPatience: const Duration(milliseconds: 20),
        sendPatience: const Duration(milliseconds: 20),
      );
      final queue = SessionQueue(
        dao: SessionQueueDao(database),
        status: status,
      );
      addTearDown(queue.close);
      SessionInput(prompts: prompts, typist: typist, queue: queue);
      queue.start();
      final queuing = SessionToolSet(
        context,
        prompts: prompts,
        registry: registry,
        queue: queue,
        typist: typist,
      );
      final agent = await runAgent('claude-code-tui');
      status.hook(hook('UserPromptSubmit'));

      final answer =
          await queuing.call('session_send', {
                'sessionId': 's1',
                'text': 'run the tests',
              }, 'caller')!
              as Map<String, Object?>;
      expect(answer['queued'], isTrue);
      expect(answer['delivered'], isFalse);
      expect(answer['position'], 1);
      expect(answer['note'], contains('Do not send it again'));
      expect(agent.writes, isEmpty);
      expect(context.write(const RelaysTo('s1', 5)).relays, hasLength(1));

      status.hook(hook('Stop'));
      final settled = await queue.settled(answer['queuedId']! as String);
      expect(settled.state, QueuedMessageState.delivered);
      expect(
        typedInto(agent),
        startsWith(
          '[message from the Karmashala session "Orchestrator" (caller)]'
          '\n\nrun the tests',
        ),
      );
    });

    test('a caller outside a session must name one', () async {
      await expectLater(
        tools.call('session_send', {'text': 'hi'}, null),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('session_wait', () {
    test('settles idle on the agent\'s Stop, done once it moved', () async {
      await runAgent('claude-code-tui');
      status.hook(hook('UserPromptSubmit'));
      final waiting = call('session_wait', {'sessionId': 's1'});
      await pumpEventQueue();
      status.hook(hook('Stop'));
      final answer = await waiting;
      expect(answer['state'], 'done');
      expect(answer['agentStatus'], 'idle');
      expect(answer['changed'], isTrue);
      expect(answer['note'], startsWith('Ready for input, and its evidence'));
    });

    test('answers timeout at the caller\'s bound, still running', () async {
      await runAgent('claude-code-tui');
      status.hook(hook('UserPromptSubmit'));
      final waiting = call('session_wait', {'sessionId': 's1'});
      await pumpEventQueue();
      deadline.complete();
      final answer = await waiting;
      expect(answer['state'], 'timeout');
      expect(answer['inputSent'], isNull);
    });

    test('answers ended with the code the host collected', () async {
      final agent = await runAgent('claude-code-tui');
      status.hook(hook('UserPromptSubmit'));
      final waiting = call('session_wait', {'sessionId': 's1'});
      await pumpEventQueue();
      agent.finish(3);
      final answer = await waiting;
      expect(answer['state'], 'ended');
      expect(answer['exitCode'], 3);
      expect(answer['exitCodeKnown'], isTrue);
    });

    test('blocked on an open prompt', () async {
      await runAgent('claude-code-permission-modal');
      final answer = await call('session_wait', {'sessionId': 's1'});
      expect(answer['state'], 'blocked');
      expect((answer['blockedOn']! as Map)['kind'], 'approvalPrompt');
    });

    test(
      'with no app, a session nothing runs has ended, code unknown',
      () async {
        final answer = await call('session_wait', {'sessionId': 's1'});
        expect(answer['state'], 'ended');
        expect(answer['exitCodeKnown'], isFalse);
        expect(answer['exitCode'], isNull);
      },
    );
  });

  group('session_transcript', () {
    test('reads the host\'s own screen, the event log and relays', () async {
      await runAgent('claude-code-tui');
      context.write(
        SessionEventsAppend([
          SessionEvent(
            sessionId: 's1',
            seq: 0,
            type: SessionEventTypes.userMessage,
            payload: jsonEncode({'text': 'hello'}),
            createdAt: t0,
          ),
        ]),
      );
      final answer = await call('session_transcript', {'sessionId': 's1'});
      expect(answer['live'], isTrue);
      expect(answer['screen'], isA<List<Object?>>());
      expect(answer['screenSource'], 'the pane as it stands now');
      expect((answer['turns']! as List).single, containsPair('text', 'hello'));
      expect(answer['turnsSource'], 'session event log');
    });

    test('with no app, a session nothing runs has no screen to read', () async {
      final answer = await call('session_transcript', {'sessionId': 's1'});
      expect(answer['live'], isFalse);
      expect(answer['screen'], isNull);
      expect(answer['turnsSource'], startsWith('not recorded'));
    });

    test('a launch that died at once still shows what it printed, and its '
        'exit code', () async {
      // Codex 0.160's refusal of `--add-dir` under a read-only sandbox,
      // as it printed it in a ConPTY before exiting 1.
      final agent = await runAgent('claude-code-tui');
      agent
        ..emit(
          utf8.encode(
            '\x1b[2J\x1b[HError adding directories: Ignoring --add-dir '
            r'(C:\data) because the effective permissions do not allow '
            'additional writable roots.\r\n',
          ),
        )
        ..finish(1);
      await pumpEventQueue();

      final answer = await call('session_transcript', {'sessionId': 's1'});
      expect(answer['live'], isFalse);
      expect(
        (answer['screen']! as List).join('\n'),
        contains('Error adding directories'),
      );
      expect(
        answer['screenSource'],
        'the pane as it stood when its process exited 1',
      );
    });
  });

  group('session_answer option: a parent picks a menu row in its child', () {
    late FakePtyHandle agent;

    setUp(() async {
      database.execute(
        "UPDATE agent_installations SET agent_kind = ? WHERE id = 'a1';",
        [AgentIds.codex],
      );
      agent = await runAgent('codex-trust-prompt-0.160');
    });

    void parentOf(String child, String parent) => database.execute(
      'UPDATE sessions SET parent_session_id = ? WHERE id = ?;',
      [parent, child],
    );

    test('the transcript lists the rows the option indexes', () async {
      final answer = await call('session_transcript', {'sessionId': 's1'});
      expect(answer['menu'], {
        'prompt': contains(startsWith('Trust this folder?')),
        'options': ['Trust and continue', 'Quit'],
        'highlighted': 0,
      });
    });

    test('in its own child: the row is chosen, by the caller', () async {
      parentOf('s1', 'caller');
      final answer = await call('session_answer', {
        'sessionId': 's1',
        'option': 0,
      }, caller: 'caller');
      expect(answer['answered'], 'Trust and continue');
      expect(typedInto(agent), '\r');
    });

    test('in a grandchild too', () async {
      insertSession('mid', title: 'Middle');
      parentOf('mid', 'caller');
      parentOf('s1', 'mid');
      final answer = await call('session_answer', {
        'sessionId': 's1',
        'option': 0,
      }, caller: 'caller');
      expect(answer['answered'], 'Trust and continue');
    });

    test('refused, nothing pressed, in a session the caller did not start, '
        'or with no calling session', () async {
      for (final caller in ['caller', null]) {
        await expectLater(
          tools.call('session_answer', {
            'sessionId': 's1',
            'option': 1,
          }, caller),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('is not a session you started'),
            ),
          ),
        );
      }
      expect(agent.writes, isEmpty);
    });

    test(
      'a row past the end, or option beside a decision, is refused',
      () async {
        parentOf('s1', 'caller');
        await expectLater(
          tools.call('session_answer', {
            'sessionId': 's1',
            'option': 2,
          }, 'caller'),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('0 "Trust and continue", 1 "Quit"'),
            ),
          ),
        );
        await expectLater(
          tools.call('session_answer', {
            'sessionId': 's1',
            'option': 0,
            'decision': 'approve',
          }, 'caller'),
          throwsA(isA<ArgumentError>()),
        );
        expect(agent.writes, isEmpty);
      },
    );
  });

  group('session_end', () {
    test('closes the session the host runs; the row survives', () async {
      await runAgent('claude-code-tui');
      final answer = await call('session_end', {'sessionId': 's1'});
      expect(answer['ended'], isTrue);
      expect(registry.find('karmashala_s1'), isNull);
      expect(SessionDao(database).getById('s1'), isNotNull);
    });

    test('cancels what waits for it, naming the ending', () async {
      final queue = SessionQueue(
        dao: SessionQueueDao(database),
        status: status,
      );
      addTearDown(queue.close);
      queue.start();
      final ending = SessionToolSet(
        context,
        prompts: prompts,
        registry: registry,
        queue: queue,
        typist: SessionToolSet.typistOver(prompts),
      );
      await runAgent('claude-code-tui');
      SessionQueueDao(database).enqueue(
        id: 'w',
        sessionId: 's1',
        text: 'waiting',
        origin: QueuedMessageOrigin.app,
        now: t0,
      );
      await ending.call('session_end', {'sessionId': 's1'}, 'caller')!;
      final row = SessionQueueDao(database).getById('w')!;
      expect(row.state, QueuedMessageState.cancelled);
      expect(row.cancelledBy, kCancelledBySessionEnd);
      expect(row.error, contains('session_end'));
    });

    test('with no app, nothing running is said, never a success', () async {
      await expectLater(
        tools.call('session_end', {'sessionId': 's1'}, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            startsWith('Nothing is running that session'),
          ),
        ),
      );
    });
  });

  group('session_rename', () {
    test('with no app, the row is renamed as the person\'s title', () async {
      final answer = await call('session_rename', {
        'sessionId': 's1',
        'title': '  Checkout flow  ',
      });
      expect(answer['title'], 'Checkout flow');
      final row = SessionDao(database).getById('s1')!;
      expect(row.title, 'Checkout flow');
      expect(row.titleByUser, isTrue);
    });

    test('a send and an end are told who made them, for the delegation '
        'push; a send that waited is not', () async {
      final sent = <(String?, String, DateTime)>[];
      final ended = <(String?, String)>[];
      final told = SessionToolSet(
        context,
        prompts: prompts,
        registry: registry,
        waits: HostedSessionWait(
          status: status,
          deadline: (_) => deadline.future,
        ),
        typist: SessionToolSet.typistOver(
          prompts,
          poll: const Duration(milliseconds: 2),
          typedPatience: const Duration(milliseconds: 20),
          sendPatience: const Duration(milliseconds: 20),
        ),
        sentBy: (caller, id, at) => sent.add((caller, id, at)),
        endedBy: (caller, id) => ended.add((caller, id)),
      );
      await runAgent('claude-code-tui');
      await told.call('session_send', {
        'sessionId': 's1',
        'text': 'next part',
      }, 'caller');
      expect(sent, [('caller', 's1', t0)]);

      final waiting = told.call('session_send', {
        'sessionId': 's1',
        'text': 'and wait',
        'wait': true,
      }, 'caller')!;
      deadline.complete();
      await waiting;
      expect(sent, hasLength(1));

      await told.call('session_end', {'sessionId': 's1'}, 'caller');
      expect(ended, [('caller', 's1')]);
    });

    test('every tool here answers itself: none is ever handed on', () {
      for (final tool in [
        'session_send',
        'session_answer',
        'session_wait',
        'session_transcript',
        'session_rename',
        'session_end',
      ]) {
        final answer = tools.call(tool, {
          'sessionId': 's1',
          'text': 'x',
          'title': 'x',
          'decision': 'approve',
        }, null);
        expect(answer, isNotNull, reason: tool);
        unawaited(answer!.then((_) {}, onError: (_) {}));
      }
    });
  });
}
