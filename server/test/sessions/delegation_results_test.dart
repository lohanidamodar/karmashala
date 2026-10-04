import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/acp/acp_runtime_host.dart';
import 'package:karmashala_host/src/acp/acp_session_runtime.dart';
import 'package:karmashala_host/src/sessions/delegation_results.dart';
import 'package:karmashala_host/src/sessions/session_queue.dart';
import 'package:karmashala_host/src/status/child_turn_wait.dart';
import 'package:karmashala_host/src/status/daemon_agent_status.dart';
import 'package:karmashala_host/src/status/hosted_session_wait.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import '../acp/acp_fixture.dart';

/// A child started in async mode reports back by itself: when its first turn
/// ends, its result is put into the parent's server queue — delivered at once
/// to an idle parent, held for a busy one's turn end, and batched when
/// several land together. Terminal and ACP children alike.
void main() {
  final t0 = DateTime.utc(2026, 10, 4, 12);

  late AppDatabase database;
  late SessionRegistry registry;
  late FakePtyLauncher pty;
  late DaemonAgentStatus status;
  late SessionQueueDao dao;
  late SessionQueue queue;
  late Map<String, List<String>> delivered;
  late Map<String, String> answers;
  // When each answer was said, for a follow-up that must not read the last.
  late Map<String, DateTime> answeredAt;
  late List<String> ended;
  late DelegationResults delegations;
  late ChildTurnWait turns;
  late Directory temp;
  var clock = t0;

  void insertSession(String id, String installation, {String? parent}) =>
      SessionDao(database).insert(
        Session(
          id: id,
          repositoryId: 'r1',
          agentInstallationId: installation,
          title: 'Session $id',
          useWorktree: false,
          status: SessionStatus.running,
          createdAt: t0,
          parentSessionId: parent,
        ),
      );

  Future<({String text, DateTime? at})?> answerOf(
    String sessionId, {
    DateTime? since,
  }) async => switch (answers[sessionId]) {
    String()
        when since != null &&
            (answeredAt[sessionId]?.isBefore(since) ?? false) =>
      null,
    final text? => (text: text, at: answeredAt[sessionId]),
    null => null,
  };

  /// A tracker over this test's database, as a server builds one at start.
  DelegationResults tracker() => DelegationResults(
    turnOf: (childId, since) => turns.firstTurn(
      childId,
      bound: const Duration(minutes: 5),
      since: since,
    ),
    answerOf: answerOf,
    queue: queue,
    store: SessionDelegationDao(database),
    isLive: status.holds,
    restoreGrace: const Duration(milliseconds: 60),
    endChild: (childId) async => ended.add(childId),
    batchWindow: const Duration(milliseconds: 40),
    now: () => clock,
  );

  setUp(() {
    clock = t0;
    temp = Directory.systemTemp.createTempSync('delegation_results_test');
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    database.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?);',
      ['r1', 'p1', 'shop-api', 'local', '/src/shop/api', '$t0'],
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
    insertSession('parent', 'a1');
    insertSession('c1', 'a1', parent: 'parent');
    insertSession('c2', 'a2', parent: 'parent');
    pty = FakePtyLauncher();
    registry = SessionRegistry(launcher: pty);
    status = DaemonAgentStatus(
      registry: registry,
      database: database,
      publish: (_, _) {},
      interval: const Duration(hours: 1),
    );
    dao = SessionQueueDao(database);
    delivered = {};
    answers = {};
    answeredAt = {};
    ended = [];
    var n = 0;
    queue =
        SessionQueue(
            dao: dao,
            status: status,
            turnStartGrace: const Duration(milliseconds: 30),
            quietPeriod: const Duration(seconds: 30),
            quietPoll: const Duration(milliseconds: 10),
            newId: () => 'q${++n}',
            now: () => t0,
          )
          ..deliver = ((sessionId, text) async =>
              (delivered[sessionId] ??= []).add(text));
    queue.start();
    turns = ChildTurnWait(
      waits: HostedSessionWait(status: status),
      answerOf: answerOf,
      settled: queue.turns.settled,
      recheck: const Duration(milliseconds: 5),
    );
    delegations = tracker();
  });

  tearDown(() async {
    await delegations.close();
    await queue.close();
    await status.close();
    for (final handle in pty.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    database.close();
    temp.deleteSync(recursive: true);
  });

  /// Runs a Claude Code TUI for [sessionId] as a terminal session.
  Future<void> runTerminal(String sessionId) async {
    final text = File(
      '../app/test/features/agents/fixtures/claude-code-tui.raw',
    ).readAsStringSync();
    final teardown = text.indexOf('Session terminated');
    registry.open(
      'karmashala_$sessionId',
      PtySpawnRequest(
        argv: const ['claude'],
        workingDirectory: '/src/shop/api',
        environment: const {},
        columns: 120,
        rows: 30,
      ),
    );
    pty.handles.last.emit(
      utf8.encode(teardown < 0 ? text : text.substring(0, teardown)),
    );
    await pumpEventQueue();
    status.tick();
  }

  void hook(String sessionId, String event) => status.hook(
    AgentHookEvent(
      agent: AgentIds.claudeCode,
      event: event,
      sessionHeader: sessionId,
      receivedAt: DateTime.now().toUtc(),
      body: {'session_id': 'conv-$sessionId', 'hook_event_name': event},
    ),
  );

  /// Starts c2 as an ACP agent whose one turn, once sent, says [answer].
  Future<AcpSessionRuntime> runAcp(String answer) async {
    final process = FakeAcpProcess(
      FakeAcpAgent(
        turns: [
          FakeTurn([FakeStep.message(answer)]),
        ],
      ),
    );
    final runtime = registry.openAcp(
      'karmashala_c2',
      runtimeOver(
        process,
        database: database,
        workingDirectory: temp.path,
        sessionId: 'c2',
        host: _DaemonHost(status),
      ),
    );
    await runtime.start();
    status.tick();
    return runtime;
  }

  DelegatedChild child(String id, {String agent = 'Claude Code'}) =>
      DelegatedChild(
        childId: id,
        parentId: 'parent',
        title: 'Task $id',
        agent: agent,
        model: 'claude-haiku',
        startedAt: t0,
      );

  Future<void> settle() async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await pumpEventQueue();
  }

  test("a terminal child's result wakes an idle parent, tagged with where it "
      'came from', () async {
    await runTerminal('parent');
    hook('parent', 'Stop');
    await runTerminal('c1');
    delegations.watch(child('c1'));
    hook('c1', 'UserPromptSubmit');
    await pumpEventQueue();
    clock = t0.add(const Duration(minutes: 2, seconds: 5));
    answers['c1'] = 'The bug is in cart.dart line 40.';
    hook('c1', 'Stop');
    await settle();

    final message = delivered['parent']!.single;
    expect(message, startsWith('[Karmashala]'));
    expect(message, contains('c1'));
    expect(message, contains('Task c1'));
    expect(message, contains('Claude Code'));
    expect(message, contains('claude-haiku'));
    expect(message, contains('2m 5s'));
    expect(message, contains('The bug is in cart.dart line 40.'));
    expect(message, contains('session_transcript'));
    final row = dao.open('parent');
    expect(row, isEmpty, reason: 'delivered rows are no longer open');
    expect(delegations.watching('parent'), isEmpty);
  });

  test('a busy parent gets the result queued for after its turn, never '
      'typed over it', () async {
    await runTerminal('parent');
    hook('parent', 'UserPromptSubmit');
    await runTerminal('c1');
    delegations.watch(child('c1'));
    hook('c1', 'UserPromptSubmit');
    await pumpEventQueue();
    answers['c1'] = 'Done.';
    hook('c1', 'Stop');
    await settle();

    expect(delivered['parent'], isNull);
    final waiting = queue.list('parent').single;
    expect(waiting.origin, QueuedMessageOrigin.delegation);
    expect(waiting.originId, 'c1');
    expect(waiting.state, QueuedMessageState.queued);

    hook('parent', 'Stop');
    await settle();
    expect(delivered['parent'], hasLength(1));
    expect(delivered['parent']!.single, contains('Done.'));
  });

  test('a terminal and an ACP child finishing together reach a busy parent '
      'as one message', () async {
    await runTerminal('parent');
    hook('parent', 'UserPromptSubmit');
    await runTerminal('c1');
    final acp = await runAcp('ACP says hello.');
    delegations
      ..watch(child('c1'))
      ..watch(child('c2', agent: 'Claude (ACP)'));
    hook('c1', 'UserPromptSubmit');
    await pumpEventQueue();
    answers['c1'] = 'Terminal says hi.';
    hook('c1', 'Stop');
    await settle();
    await acp.send('task');
    await acp.awaitTurn();
    answers['c2'] = 'ACP says hello.';
    await settle();

    final waiting = queue.list('parent');
    expect(waiting, hasLength(1), reason: 'batched into one queued row');
    expect(waiting.single.text, contains('Terminal says hi.'));
    expect(waiting.single.text, contains('ACP says hello.'));
    expect(waiting.single.text, contains('2 sessions'));

    hook('parent', 'Stop');
    await settle();
    expect(delivered['parent'], hasLength(1));
  });

  test('results landing together at an idle parent are batched too', () async {
    await runTerminal('parent');
    hook('parent', 'Stop');
    await runTerminal('c1');
    final acp = await runAcp('From ACP.');
    delegations
      ..watch(child('c1'))
      ..watch(child('c2'));
    hook('c1', 'UserPromptSubmit');
    await pumpEventQueue();
    answers['c1'] = 'From the terminal.';
    hook('c1', 'Stop');
    await acp.send('task');
    await acp.awaitTurn();
    answers['c2'] = 'From ACP.';
    await settle();

    final message = delivered['parent']!.single;
    expect(message, contains('From the terminal.'));
    expect(message, contains('From ACP.'));
  });

  test('an answer past the bound is cut, with a pointer to the rest; a '
      'child asked to end once it answers is ended', () async {
    await runTerminal('parent');
    hook('parent', 'Stop');
    await runTerminal('c1');
    delegations.watch(
      DelegatedChild(
        childId: 'c1',
        parentId: 'parent',
        title: 'Long',
        agent: 'Claude Code',
        startedAt: t0,
        endOnAnswer: true,
      ),
    );
    hook('c1', 'UserPromptSubmit');
    await pumpEventQueue();
    answers['c1'] = 'x' * (kDelegationAnswerMaxChars + 500);
    hook('c1', 'Stop');
    await settle();

    final message = delivered['parent']!.single;
    expect(message, isNot(contains('x' * (kDelegationAnswerMaxChars + 1))));
    expect(message, contains('cut at $kDelegationAnswerMaxChars'));
    expect(message, contains("the agent's default"));
    expect(ended, ['c1']);
  });

  test('a child a person stops is forgotten, so it does not wake its '
      'parent', () async {
    await runTerminal('parent');
    hook('parent', 'Stop');
    await runTerminal('c1');
    delegations.watch(child('c1'));
    hook('c1', 'UserPromptSubmit');
    await pumpEventQueue();
    delegations.stopped('c1');
    answers['c1'] = 'partial';
    hook('c1', 'Stop');
    await settle();
    expect(delivered['parent'], isNull);
    expect(queue.list('parent'), isEmpty);
  });

  test("a child blocked on a person reports that, not an answer", () async {
    await runTerminal('parent');
    hook('parent', 'Stop');
    final text = File(
      '../app/test/features/agents/fixtures/claude-code-permission-modal.raw',
    ).readAsStringSync();
    registry.open(
      'karmashala_c1',
      PtySpawnRequest(
        argv: const ['claude'],
        workingDirectory: '/src/shop/api',
        environment: const {},
        columns: 120,
        rows: 30,
      ),
    );
    delegations.watch(child('c1'));
    pty.handles.last.emit(utf8.encode(text));
    await pumpEventQueue();
    status.tick();
    await settle();
    final message = delivered['parent']!.single;
    expect(message, contains('BLOCKED'));
    expect(message, contains('session_answer'));
  });

  group('across a restart', () {
    test('a child still running is watched again by the next tracker, and '
        'its result pushed', () async {
      await runTerminal('parent');
      hook('parent', 'Stop');
      await runTerminal('c1');
      delegations.watch(child('c1'));
      await delegations.close();
      expect(SessionDelegationDao(database).awaiting(), hasLength(1));

      delegations = tracker()..start();
      hook('c1', 'UserPromptSubmit');
      await pumpEventQueue();
      answers['c1'] = 'Back after the restart.';
      hook('c1', 'Stop');
      await settle();

      expect(delivered['parent']!.single, contains('Back after the restart.'));
      expect(SessionDelegationDao(database).awaiting(), isEmpty);
    });

    test('a child that finished while the server was down has its result '
        'pushed once on start', () async {
      await runTerminal('parent');
      hook('parent', 'Stop');
      await runTerminal('c1');
      delegations.watch(child('c1'));
      await delegations.close();
      // Down: the child answers and its process goes.
      answers['c1'] = 'Finished while you were away.';
      pty.handles.last.finish(0);
      await pumpEventQueue();

      delegations = tracker()..start();
      await settle();
      expect(
        delivered['parent']!.single,
        contains('Finished while you were away.'),
      );
      expect(delivered['parent']!.single, contains('— done'));

      await delegations.close();
      delegations = tracker()..start();
      await settle();
      expect(delivered['parent'], hasLength(1), reason: 'pushed once');
    });
  });

  group('follow-up turns', () {
    Future<void> firstTurnReported() async {
      await runTerminal('parent');
      hook('parent', 'Stop');
      await runTerminal('c1');
      delegations.watch(child('c1'));
      hook('c1', 'UserPromptSubmit');
      await pumpEventQueue();
      answers['c1'] = 'First answer.';
      answeredAt['c1'] = clock;
      hook('c1', 'Stop');
      await settle();
      expect(delivered['parent'], hasLength(1));
    }

    test("the parent's follow-up to its async child has that turn's result "
        'pushed too', () async {
      await firstTurnReported();
      clock = t0.add(const Duration(minutes: 10));
      delegations.sent('parent', 'c1');
      hook('parent', 'UserPromptSubmit');
      hook('parent', 'Stop');
      hook('c1', 'UserPromptSubmit');
      await pumpEventQueue();
      answers['c1'] = 'Second answer.';
      answeredAt['c1'] = clock;
      hook('c1', 'Stop');
      await settle();

      expect(delivered['parent'], hasLength(2));
      expect(delivered['parent']!.last, contains('Second answer.'));
      expect(delivered['parent']!.last, contains('turn 2'));
    });

    test('a message from anyone but the parent arms nothing', () async {
      await firstTurnReported();
      delegations.sent('someone-else', 'c1');
      delegations.sent(null, 'c1');
      expect(SessionDelegationDao(database).awaiting(), isEmpty);
    });

    test('a follow-up sent mid-turn is reported after the turn it lands '
        'behind', () async {
      await runTerminal('parent');
      hook('parent', 'Stop');
      await runTerminal('c1');
      delegations.watch(child('c1'));
      hook('c1', 'UserPromptSubmit');
      await pumpEventQueue();
      delegations.sent('parent', 'c1');
      answers['c1'] = 'First answer.';
      answeredAt['c1'] = clock;
      // The next turn is awaited from when this one was reported.
      clock = t0.add(const Duration(minutes: 1));
      hook('c1', 'Stop');
      await settle();
      expect(delivered['parent'], hasLength(1));
      expect(SessionDelegationDao(database).awaiting(), hasLength(1));

      hook('parent', 'UserPromptSubmit');
      hook('parent', 'Stop');
      hook('c1', 'UserPromptSubmit');
      await pumpEventQueue();
      answers['c1'] = 'Answer to the follow-up.';
      answeredAt['c1'] = clock;
      hook('c1', 'Stop');
      await settle();
      expect(delivered['parent'], hasLength(2));
      expect(delivered['parent']!.last, contains('Answer to the follow-up.'));
    });

    test('once the parent stops it, nothing more is pushed', () async {
      await firstTurnReported();
      delegations.stopped('c1');
      expect(SessionDelegationDao(database).byChild('c1'), isNull);
      delegations.sent('parent', 'c1');
      expect(SessionDelegationDao(database).awaiting(), isEmpty);
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
