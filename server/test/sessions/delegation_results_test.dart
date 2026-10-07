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
  late Set<String> archived;
  late DelegationResults delegations;
  late ChildTurnWait turns;
  late HostedSessionWait waits;
  // A child's open prompt as a test sets it; one not set reads the screen.
  late Map<String, String?> asks;
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
    nextTurnOf: (childId, since) => turns.nextTurn(childId, since: since),
    answerOf: answerOf,
    queue: queue,
    store: SessionDelegationDao(database),
    isLive: status.holds,
    isArchived: archived.contains,
    openAskOf: (id) => asks.containsKey(id) ? asks[id] : waits.openAskOf(id),
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
    archived = {};
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
    asks = {};
    waits = HostedSessionWait(status: status);
    turns = ChildTurnWait(
      waits: waits,
      answerOf: answerOf,
      settled: queue.turns.settled,
      recheck: const Duration(milliseconds: 5),
    );
    delegations = tracker();
    queue.restate = delegations.restate;
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
    expect(
      delegations.watching('parent').single.childId,
      'c1',
      reason: 'the turn it works next is followed too',
    );
    final kept = SessionDelegationDao(database).byChild('c1')!;
    expect(kept.reportState, 'done');
    expect(kept.reportVia, 'turn');
    expect(kept.reportedAt, clock);
  });

  test('a child whose turn an API error ended is reported blocked, stopped '
      'on an error, with how to resume it', () async {
    await runTerminal('parent');
    hook('parent', 'Stop');
    await runTerminal('c1');
    delegations.watch(child('c1'));
    hook('c1', 'UserPromptSubmit');
    await pumpEventQueue();
    status.hook(
      AgentHookEvent(
        agent: AgentIds.claudeCode,
        event: 'StopFailure',
        sessionHeader: 'c1',
        receivedAt: DateTime.now().toUtc(),
        body: {
          'session_id': 'conv-c1',
          'hook_event_name': 'StopFailure',
          'error': 'server_error',
        },
      ),
    );
    await settle();

    final message = delivered['parent']!.single;
    expect(message, contains('BLOCKED: stopped on an error'));
    expect(message, contains('session_send'));
    expect(
      SessionDelegationDao(database).byChild('c1')!.reportState,
      'blocked',
    );
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

    // The same prompt, still open, is not a second turn.
    for (var i = 0; i < 3; i++) {
      status.tick();
      await settle();
    }
    expect(delivered['parent'], hasLength(1));
  });

  group('a blocked result whose prompt is gone', () {
    /// Opens c1 on Claude Code's permission prompt, followed by its parent.
    Future<void> blockC1() async {
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
    }

    test('the screen names the prompt it shows', () async {
      await runTerminal('parent');
      hook('parent', 'Stop');
      await blockC1();
      expect(waits.openAskOf('c1'), startsWith('approval:'));
      expect(waits.openAskOf('parent'), isNull);
    });

    test(
      'is not delivered when answered while it waited in the queue',
      () async {
        await runTerminal('parent');
        hook('parent', 'UserPromptSubmit');
        asks['c1'] = 'approval:tool-1';
        await blockC1();
        final waiting = queue.list('parent').single;
        expect(waiting.state, QueuedMessageState.queued);

        asks['c1'] = null;
        hook('parent', 'Stop');
        await settle();
        expect(delivered['parent'], isNull);
        expect(dao.getById(waiting.id)!.state, QueuedMessageState.cancelled);
      },
    );

    test(
      'is not queued when another prompt replaced it before it went',
      () async {
        await runTerminal('parent');
        hook('parent', 'Stop');
        asks['c1'] = 'approval:tool-1';
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
        pty.handles.last.emit(
          utf8.encode(
            File(
              '../app/test/features/agents/fixtures/'
              'claude-code-permission-modal.raw',
            ).readAsStringSync(),
          ),
        );
        await pumpEventQueue();
        status.tick();
        // Inside the batch window: the next prompt is up before it is sent.
        await Future<void>.delayed(const Duration(milliseconds: 10));
        asks['c1'] = 'approval:tool-2';
        await settle();
        expect(delivered['parent'], isNull);
        expect(queue.list('parent'), isEmpty);
      },
    );

    test('one still open is delivered', () async {
      await runTerminal('parent');
      hook('parent', 'UserPromptSubmit');
      asks['c1'] = 'approval:tool-1';
      await blockC1();
      hook('parent', 'Stop');
      await settle();
      expect(delivered['parent']!.single, contains('BLOCKED'));
    });
  });

  group('report_to_parent', () {
    ParentReport report(String id, ReportStatus status, String text) =>
        ParentReport(
          childId: id,
          parentId: 'parent',
          title: 'Task $id',
          agent: 'Claude Code',
          status: status,
          text: text,
        );

    test('a report reaches an idle parent at once, naming the child, and '
        'is kept as its last', () async {
      await runTerminal('parent');
      hook('parent', 'Stop');
      await runTerminal('c1');
      delegations.watch(child('c1'));
      hook('c1', 'UserPromptSubmit');
      await pumpEventQueue();
      clock = t0.add(const Duration(minutes: 4));
      delegations.report(report('c1', ReportStatus.done, 'All five fixed.'));
      await pumpEventQueue();

      final message = delivered['parent']!.single;
      expect(message, startsWith('[Karmashala]'));
      expect(message, contains('"Task c1"'));
      expect(message, contains('c1'));
      expect(message, contains('done'));
      expect(message, contains('All five fixed.'));
      final row = SessionDelegationDao(database).byChild('c1')!;
      expect(row.reportState, 'done');
      expect(row.reportVia, 'report');
      expect(row.reportedAt, clock);
    });

    test('the turn it reported in is not pushed again; the next is', () async {
      await runTerminal('parent');
      hook('parent', 'Stop');
      await runTerminal('c1');
      delegations.watch(child('c1'));
      hook('c1', 'UserPromptSubmit');
      await pumpEventQueue();
      clock = t0.add(const Duration(minutes: 4));
      delegations.report(report('c1', ReportStatus.done, 'All five fixed.'));
      answers['c1'] = 'All five fixed.';
      answeredAt['c1'] = clock;
      hook('c1', 'Stop');
      await settle();
      expect(delivered['parent'], hasLength(1));

      clock = t0.add(const Duration(minutes: 10));
      hook('c1', 'UserPromptSubmit');
      await pumpEventQueue();
      answers['c1'] = 'And a sixth.';
      answeredAt['c1'] = clock;
      hook('c1', 'Stop');
      await settle();
      expect(delivered['parent'], hasLength(2));
      expect(delivered['parent']!.last, contains('And a sixth.'));
      final row = SessionDelegationDao(database).byChild('c1')!;
      expect(row.reportVia, 'turn');
    });

    test(
      'a child nothing follows is delivered and kept, not followed',
      () async {
        await runTerminal('parent');
        hook('parent', 'Stop');
        delegations.report(
          report('c1', ReportStatus.needsInput, 'Which branch?'),
        );
        await pumpEventQueue();
        final message = delivered['parent']!.single;
        expect(message, contains('Which branch?'));
        expect(message, contains('needs input'));
        final row = SessionDelegationDao(database).byChild('c1')!;
        expect(row.isOpen, isFalse);
        expect(row.reportState, 'needs_input');
        expect(delegations.watching('parent'), isEmpty);
      },
    );
  });

  group('report modes', () {
    DelegatedChild childIn(String id, String mode) => DelegatedChild(
      childId: id,
      parentId: 'parent',
      title: 'Task $id',
      agent: 'Claude Code',
      startedAt: t0,
      reportMode: mode,
    );

    Future<void> works(String id, String answer) async {
      hook(id, 'UserPromptSubmit');
      await pumpEventQueue();
      clock = clock.add(const Duration(minutes: 1));
      answers[id] = answer;
      answeredAt[id] = clock;
      hook(id, 'Stop');
      await settle();
    }

    test(
      'none: nothing comes back, and the child is recorded unfollowed',
      () async {
        await runTerminal('parent');
        hook('parent', 'Stop');
        await runTerminal('c1');
        delegations.watch(childIn('c1', kReportModeNone));
        await works('c1', 'Did it.');
        expect(delivered['parent'], isNull);
        expect(delegations.watching('parent'), isEmpty);
        final row = SessionDelegationDao(database).byChild('c1')!;
        expect(row.reportMode, kReportModeNone);
        expect(row.isOpen, isFalse);
        expect(
          delegations.report(
            ParentReport(
              childId: 'c1',
              parentId: 'parent',
              title: 'Task c1',
              agent: 'Claude Code',
              status: ReportStatus.done,
              text: 'Done anyway.',
            ),
          ),
          ReportDelivery.notWanted,
        );
        await pumpEventQueue();
        expect(delivered['parent'], isNull);
        expect(
          SessionDelegationDao(database).byChild('c1')!.reportText,
          'Done anyway.',
        );
      },
    );

    test('final: a turn that finishes without a report says so; its end '
        'still comes, without repeating the answer', () async {
      await runTerminal('parent');
      hook('parent', 'Stop');
      await runTerminal('c1');
      delegations.watch(childIn('c1', kReportModeFinal));
      await works('c1', 'First pass.');
      expect(
        delivered['parent']!.single,
        contains('"Task c1" — finished its turn without reporting'),
      );
      expect(delivered['parent']!.single, contains('First pass.'));
      expect(delivered['parent']!.single, contains('report_to_parent'));
      await works('c1', 'Second pass.');
      expect(delivered['parent'], hasLength(2));
      expect(delivered['parent']!.last, contains('Second pass.'));

      // Said a moment before its push, as a real answer is.
      answeredAt['c1'] = clock.subtract(const Duration(seconds: 1));
      pty.handles.last.finish(0);
      await settle();
      expect(delivered['parent'], hasLength(3));
      final message = delivered['parent']!.last;
      expect(message, contains('ended'));
      expect(message, isNot(contains('Second pass.')));
      expect(SessionDelegationDao(database).byChild('c1')!.isOpen, isFalse);
    });

    test(
      'final: a turn the child reported in brings only its report',
      () async {
        await runTerminal('parent');
        hook('parent', 'Stop');
        await runTerminal('c1');
        delegations.watch(childIn('c1', kReportModeFinal));
        hook('c1', 'UserPromptSubmit');
        await pumpEventQueue();
        clock = t0.add(const Duration(minutes: 2));
        delegations.report(
          ParentReport(
            childId: 'c1',
            parentId: 'parent',
            title: 'Task c1',
            agent: 'Claude Code',
            status: ReportStatus.done,
            text: 'Reported myself.',
          ),
        );
        answers['c1'] = 'Reported myself.';
        answeredAt['c1'] = clock;
        hook('c1', 'Stop');
        await settle();
        expect(delivered['parent'], hasLength(1));
        expect(
          delivered['parent']!.single,
          isNot(contains('without reporting')),
        );
      },
    );

    test(
      'final: a child that reported is not pushed again when it ends',
      () async {
        await runTerminal('parent');
        hook('parent', 'Stop');
        await runTerminal('c1');
        delegations.watch(childIn('c1', kReportModeFinal));
        hook('c1', 'UserPromptSubmit');
        await pumpEventQueue();
        clock = t0.add(const Duration(minutes: 2));
        delegations.report(
          ParentReport(
            childId: 'c1',
            parentId: 'parent',
            title: 'Task c1',
            agent: 'Claude Code',
            status: ReportStatus.done,
            text: 'All done.',
          ),
        );
        answers['c1'] = 'All done.';
        hook('c1', 'Stop');
        await settle();
        pty.handles.last.finish(0);
        await settle();
        expect(delivered['parent'], hasLength(1));
        expect(delivered['parent']!.single, contains('All done.'));
      },
    );

    test('final: a child blocked on a person is pushed', () async {
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
      delegations.watch(childIn('c1', kReportModeFinal));
      pty.handles.last.emit(utf8.encode(text));
      await pumpEventQueue();
      status.tick();
      await settle();
      expect(delivered['parent']!.single, contains('BLOCKED'));
    });

    test('the parent can change it later: none to each_turn starts '
        'following', () async {
      await runTerminal('parent');
      hook('parent', 'Stop');
      await runTerminal('c1');
      delegations.watch(childIn('c1', kReportModeNone));
      expect(
        delegations.setMode(childIn('c1', kReportModeEachTurn), 'parent'),
        isTrue,
      );
      await works('c1', 'Now you hear me.');
      expect(delivered['parent']!.single, contains('Now you hear me.'));
      expect(
        delegations.setMode(childIn('c1', kReportModeNone), 'parent'),
        isTrue,
      );
      expect(delegations.watching('parent'), isEmpty);
      await works('c1', 'Quiet again.');
      expect(delivered['parent'], hasLength(1));
      expect(
        delegations.setMode(childIn('c1', kReportModeFinal), 'someone-else'),
        isFalse,
      );
    });

    test(
      "a parent's turn on a report does not set its child off again",
      () async {
        await runTerminal('parent');
        hook('parent', 'Stop');
        await runTerminal('c1');
        delegations.watch(childIn('c1', kReportModeEachTurn));
        await works('c1', 'Here.');
        expect(delivered['parent'], hasLength(1));
        // The report wakes the parent; its turn runs and ends.
        hook('parent', 'UserPromptSubmit');
        hook('parent', 'Stop');
        await settle();
        await settle();
        expect(delivered['parent'], hasLength(1));
        expect(delivered['c1'], isNull);
      },
    );
  });

  group('a parent that is gone', () {
    test('is never queued a result or a report; both are kept on the '
        "child's delegation", () async {
      await runTerminal('c1');
      // No process runs the parent.
      delegations.watch(child('c1'));
      await pumpEventQueue();
      hook('c1', 'UserPromptSubmit');
      await pumpEventQueue();
      answers['c1'] = 'Finished, nobody listening.';
      hook('c1', 'Stop');
      await settle();
      expect(queue.list('parent'), isEmpty);
      expect(delivered['parent'], isNull);
      var row = SessionDelegationDao(database).byChild('c1')!;
      expect(row.reportDelivered, isFalse);
      expect(row.reportText, contains('Finished, nobody listening.'));

      expect(
        delegations.report(
          ParentReport(
            childId: 'c1',
            parentId: 'parent',
            title: 'Task c1',
            agent: 'Claude Code',
            status: ReportStatus.done,
            text: 'Final word.',
          ),
        ),
        ReportDelivery.parentGone,
      );
      expect(queue.list('parent'), isEmpty);
      row = SessionDelegationDao(database).byChild('c1')!;
      expect(row.reportText, 'Final word.');
      expect(row.reportDelivered, isFalse);
    });
  });

  group('where a child stands', () {
    test('running until its first push, then its last report; ended once '
        'nothing runs it', () async {
      await runTerminal('parent');
      hook('parent', 'Stop');
      await runTerminal('c1');
      delegations.watch(child('c1'));
      expect(delegations.viewOf('c1').state, 'running');
      expect(delegations.viewOf('c1').followed, isTrue);
      expect(delegations.viewOf('c1').reportedAt, isNull);

      hook('c1', 'UserPromptSubmit');
      await pumpEventQueue();
      expect(delegations.viewOf('c1').state, 'running');
      clock = t0.add(const Duration(minutes: 3));
      delegations.report(
        ParentReport(
          childId: 'c1',
          parentId: 'parent',
          title: 'Task c1',
          agent: 'Claude Code',
          status: ReportStatus.done,
          text: 'Done.',
        ),
      );
      answers['c1'] = 'Done.';
      hook('c1', 'Stop');
      await settle();
      final done = delegations.viewOf('c1');
      expect(done.state, 'reported done');
      expect(done.reportVia, kReportViaChild);
      expect(done.reportedAt, clock);

      pty.handles.last.finish(0);
      await settle();
      expect(delegations.viewOf('c1').state, 'ended');
      expect(delegations.viewOf('c1').reportedAt, clock);
    });

    test('a child that reported blocked reads blocked', () async {
      await runTerminal('parent');
      hook('parent', 'Stop');
      await runTerminal('c1');
      delegations.report(
        ParentReport(
          childId: 'c1',
          parentId: 'parent',
          title: 'Task c1',
          agent: 'Claude Code',
          status: ReportStatus.blocked,
          text: 'No access to the bucket.',
        ),
      );
      final view = delegations.viewOf('c1');
      expect(view.state, 'blocked');
      expect(view.followed, isFalse);
    });

    test('a child nothing recorded and nothing runs is ended, not '
        'reported', () {
      final view = delegations.viewOf('c2');
      expect(view.state, 'ended');
      expect(view.reportState, isNull);
    });
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

    test('every turn the child works is pushed, though the parent armed '
        'none', () async {
      await firstTurnReported();
      clock = t0.add(const Duration(minutes: 10));
      // A person, or a message queued earlier, starts the child again.
      hook('c1', 'UserPromptSubmit');
      await pumpEventQueue();
      answers['c1'] = 'Second answer.';
      answeredAt['c1'] = clock;
      hook('c1', 'Stop');
      await settle();
      expect(delivered['parent'], hasLength(2));
      expect(delivered['parent']!.last, contains('Second answer.'));
      expect(delivered['parent']!.last, contains('turn 2'));

      hook('c1', 'UserPromptSubmit');
      await pumpEventQueue();
      answers['c1'] = 'Third answer.';
      hook('c1', 'Stop');
      await settle();
      expect(delivered['parent'], hasLength(3));
      expect(delivered['parent']!.last, contains('turn 3'));
    });

    test('a child that sits idle pushes nothing, and a turn is pushed only '
        'once', () async {
      await firstTurnReported();
      for (var i = 0; i < 3; i++) {
        status.tick();
        hook('c1', 'Stop');
        await settle();
      }
      expect(delivered['parent'], hasLength(1));
      expect(delegations.watching('parent'), hasLength(1));
    });

    test('a child that ends while idle pushes nothing', () async {
      await firstTurnReported();
      pty.handles.last.finish(0);
      await settle();
      expect(delivered['parent'], hasLength(1));
      expect(delegations.watching('parent'), isEmpty);
    });

    test('an archived child pushes nothing more', () async {
      await firstTurnReported();
      archived.add('c1');
      hook('c1', 'UserPromptSubmit');
      await pumpEventQueue();
      answers['c1'] = 'Said after it was archived.';
      hook('c1', 'Stop');
      await settle();
      expect(delivered['parent'], hasLength(1));
      expect(SessionDelegationDao(database).byChild('c1')!.isOpen, isFalse);
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
      expect(delegations.watching('parent'), hasLength(1));

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
      expect(SessionDelegationDao(database).byChild('c1')!.isOpen, isFalse);
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
