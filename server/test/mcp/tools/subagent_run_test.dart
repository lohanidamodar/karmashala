import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart' show PathProbe;
import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:karmashala_automations/resumes.dart';
import 'package:karmashala_automations/store.dart'
    show CheckoutRows, ScheduledResumeDao;
import 'package:karmashala_host/data.dart' show DataService;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/automations/daemon_checkout_facts.dart';
import 'package:karmashala_host/src/automations/hosted_agent_launcher.dart';
import 'package:karmashala_host/src/mcp/tools/launch_tool_set.dart';
import 'package:karmashala_host/src/mcp/tools/server_tool_context.dart';
import 'package:karmashala_host/src/mcp/tools/session_tool_set.dart';
import 'package:karmashala_host/src/sessions/delegation_results.dart'
    show DelegatedChild, ParentReport, ReportStatus;
import 'package:karmashala_host/src/sessions/launch/server_session_launcher.dart';
import 'package:karmashala_host/src/status/child_turn_wait.dart';
import 'package:karmashala_host/src/status/daemon_agent_status.dart';
import 'package:karmashala_host/src/status/daemon_prompt_answers.dart';
import 'package:karmashala_host/src/status/hosted_session_wait.dart';
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

final class _Everywhere implements PathProbe {
  const _Everywhere();
  @override
  bool? fileExists(String path) => true;
  @override
  bool isLink(String path) => false;
  @override
  String? linkTarget(String path) => null;
}

/// `subagent_run`: `open_new_session`'s launch — its depth cap and permission
/// ceiling — then a wait for the child's first turn, answered with what the
/// child said; a bound that runs out is `running`, a prompt is `blocked`.
void main() {
  final t0 = DateTime.utc(2026, 10, 3, 12);

  late AppDatabase database;
  late SessionRegistry registry;
  late FakePtyLauncher pty;
  late DaemonAgentStatus status;
  late ServerToolContext context;
  late Completer<void> deadline;
  late Map<String, String> answers;
  late HostedSessionWait waits;
  late LaunchToolSet tools;
  late StreamController<String> settledTurns;
  late List<String> endedChildren;
  late List<(String, bool)> holds;
  late List<DelegatedChild> delegated;
  late List<ParentReport> reports;
  var ids = 0;

  Future<({String text, DateTime? at})?> answerOf(
    String sessionId, {
    DateTime? since,
  }) async => switch (answers[sessionId]) {
    final text? => (text: text, at: null),
    null => null,
  };

  setUp(() {
    ids = 0;
    settledTurns = StreamController<String>.broadcast(sync: true);
    endedChildren = [];
    holds = [];
    delegated = [];
    reports = [];
    answers = {};
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    database.execute(
      'INSERT INTO execution_environments (id, kind, name, created_at) '
      'VALUES (?, ?, ?, ?);',
      [
        'local',
        Platform.isWindows ? 'windowsNative' : 'localPosix',
        'Here',
        t0.toIso8601String(),
      ],
    );
    database.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?);',
      ['r1', 'p1', 'shop-api', 'local', '/src/shop/api', '$t0'],
    );
    database.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at, executable_by_user) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      ['a1', AgentIds.claudeCode, 'local', '/bin/claude', '$t0', 1],
    );
    pty = FakePtyLauncher();
    registry = SessionRegistry(launcher: pty);
    status = DaemonAgentStatus(
      registry: registry,
      database: database,
      publish: (_, _) {},
      interval: const Duration(hours: 1),
    );
    context = ServerToolContext(
      database: database,
      data: DataService(database, clock: () => t0),
      dataDirectory: '/nowhere',
      clock: () => t0,
    );
    deadline = Completer<void>();
    waits = HostedSessionWait(status: status, deadline: (_) => deadline.future);
    final rows = CheckoutRows(database);
    final launcher = HostedAgentLauncher(
      registry: registry,
      sessions: SessionDao(database),
      mcp: SessionMcpAccessPoint(mcp: null, configDirectory: '/nowhere'),
      now: () => t0,
      newId: () => 'new-${++ids}',
      hostEnvironment: const {},
      environmentOf: rows.environment,
    );
    tools = LaunchToolSet(
      context,
      launches: ServerSessionLauncher(
        launcher: launcher,
        registry: registry,
        sessions: SessionDao(database),
        rows: rows,
        facts: DaemonCheckoutFacts(rows, windows: Platform.isWindows),
        installationsIn: context.data.installationsIn,
        pathProbe: const _Everywhere(),
        directoryPresent: (_) => true,
      ),
      turns: ChildTurnWait(
        waits: waits,
        answerOf: answerOf,
        settled: settledTurns.stream,
        deadline: (_) => deadline.future,
        recheck: const Duration(milliseconds: 5),
      ),
      tokensOf: (_) async => 4200,
      endChild: (sessionId) async => endedChildren.add(sessionId),
      callHolds: (sessionId, held) => holds.add((sessionId, held)),
      delegate: delegated.add,
      reportToParent: reports.add,
    );
  });

  tearDown(() async {
    context.close();
    await status.close();
    for (final handle in pty.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    database.close();
  });

  void insertCaller(
    String id, {
    String? parent,
    EnvironmentPath? worktree,
    EnvironmentPath? workingDirectory,
  }) => SessionDao(database).insert(
    Session(
      id: id,
      repositoryId: 'r1',
      agentInstallationId: 'a1',
      title: 'Orchestrator $id',
      useWorktree: worktree != null,
      worktree: worktree,
      workingDirectory: workingDirectory,
      status: SessionStatus.running,
      createdAt: t0,
      parentSessionId: parent,
      parentLink: parent == null ? null : SessionLink.spawn,
    ),
  );

  List<int> fixture(String name) {
    final text = File(
      '../app/test/features/agents/fixtures/$name.raw',
    ).readAsStringSync();
    final teardown = text.indexOf('Session terminated');
    return utf8.encode(teardown < 0 ? text : text.substring(0, teardown));
  }

  AgentHookEvent hook(String event) => AgentHookEvent(
    agent: AgentIds.claudeCode,
    event: event,
    sessionHeader: 'new-1',
    receivedAt: DateTime.now().toUtc(),
    body: {'session_id': 'conv-1', 'hook_event_name': event},
  );

  /// Starts a run as [caller] and lets the child's screen come up as
  /// [screen] draws it.
  Future<Future<Map<String, Object?>>> run(
    Map<String, Object?> arguments, {
    String caller = 'caller',
    String screen = 'claude-code-tui',
  }) async {
    final answer = tools
        .call('subagent_run', {'projectId': 'p1', ...arguments}, caller)!
        .then((value) => value! as Map<String, Object?>);
    for (var i = 0; i < 20 && pty.handles.isEmpty; i++) {
      await pumpEventQueue();
    }
    pty.handles.last.emit(fixture(screen));
    await pumpEventQueue();
    status.tick();
    return answer;
  }

  test('waits for the child\'s turn and answers with what it said', () async {
    insertCaller('caller');
    final answer = await run({
      'prompt': 'Find the cart bug',
      'model': 'claude-haiku',
    });
    status.hook(hook('UserPromptSubmit'));
    await pumpEventQueue();
    answers['new-1'] = 'It is in cart.dart line 40.';
    status.hook(hook('Stop'));
    final result = await answer.timeout(const Duration(seconds: 5));

    expect(result['state'], 'done');
    expect(result['childSessionId'], 'new-1');
    expect(result['finalAnswer'], 'It is in cart.dart line 40.');
    expect(result['model'], 'claude-haiku');
    expect(result['tokens'], 4200);
    expect(result['depth'], 1);
    final row = SessionDao(database).getById('new-1')!;
    expect(row.parentSessionId, 'caller');
    expect(row.parentLink, SessionLink.spawn);
    expect(row.modelId, 'claude-haiku');
    expect(row.title, startsWith('Subagent: Find the cart bug'));
    // Answered: ended, and the call held its turn only while it waited.
    expect(endedChildren, ['new-1']);
    expect(result['childOpen'], isFalse);
    expect(result['note'], contains('was ended once it answered'));
    expect(holds, [('new-1', true), ('new-1', false)]);
  });

  test('keepOpen leaves an answered child open', () async {
    insertCaller('caller');
    final answer = await run({'prompt': 'Look', 'keepOpen': true});
    status.hook(hook('UserPromptSubmit'));
    await pumpEventQueue();
    answers['new-1'] = 'Seen.';
    status.hook(hook('Stop'));
    final result = await answer.timeout(const Duration(seconds: 5));
    expect(result['state'], 'done');
    expect(endedChildren, isEmpty);
    expect(result['childOpen'], isTrue);
    expect(result['note'], contains('session_send'));
  });

  test('a child stopped on its limit stays open, with its resume named', () async {
    insertCaller('caller');
    final fireAt = t0.add(const Duration(hours: 3));
    ScheduledResumeDao(database).replaceFor(
      ScheduledResume(
        id: 'r1',
        sessionId: 'new-1',
        fireAt: fireAt,
        state: ScheduledResumeState.pending,
        scheduledAt: t0,
        windowLabel: '5-hour',
        message: 'continue',
      ),
      now: t0,
    );
    final answer = await run({'prompt': 'Big job'});
    status.hook(hook('UserPromptSubmit'));
    await pumpEventQueue();
    status.hook(hook('StopFailure'));
    final result = await answer.timeout(const Duration(seconds: 5));
    expect(result['state'], 'failed');
    expect(endedChildren, isEmpty);
    expect(result['childOpen'], isTrue);
    expect(result['resume'], {
      'at': fireAt.toIso8601String(),
      'message': 'continue',
      'window': '5-hour',
    });
    expect(result['note'], contains('resumes it at ${fireAt.toIso8601String()}'));
    expect(result['note'], contains('only the user can'));
  });

  test('a child ready before it ever worked is not done until it has an '
      'answer', () async {
    insertCaller('caller');
    final answer = await run({'prompt': 'Count the files'});
    status.hook(hook('Stop'));
    await pumpEventQueue();
    var settled = false;
    unawaited(answer.then((_) => settled = true));
    await pumpEventQueue();
    expect(settled, isFalse);
    answers['new-1'] = '42 files.';
    final result = await answer.timeout(const Duration(seconds: 5));
    expect(result['state'], 'done');
    expect(result['finalAnswer'], '42 files.');
  });

  test('a turn the server settles over a screen it cannot read is done, '
      'not waited out', () async {
    insertCaller('caller');
    final answer = await run({'prompt': 'Quiet job'}, screen: 'codex-tui');
    expect(
      status.statusOf('new-1')?.report.status,
      anyOf(isNull, AgentActivityStatus.unknown),
    );
    answers['new-1'] = 'Done quietly.';
    settledTurns.add('new-1');
    final result = await answer.timeout(const Duration(seconds: 5));
    expect(result['state'], 'done');
    expect(result['finalAnswer'], 'Done quietly.');
  });

  test('a settled turn over a status that says ready is read as it says', () async {
    insertCaller('caller');
    final answer = await run({'prompt': 'Not started'});
    status.hook(hook('Stop'));
    await pumpEventQueue();
    var finished = false;
    unawaited(answer.then((_) => finished = true));
    settledTurns.add('new-1');
    await pumpEventQueue();
    // Ready and never seen working, with no answer: not yet its turn's end.
    expect(finished, isFalse);
    deadline.complete();
    expect((await answer)['state'], 'running');
  });

  test('at its bound it answers running, and says how to continue', () async {
    insertCaller('caller');
    final answer = await run({'prompt': 'Long job', 'timeoutSeconds': 5});
    status.hook(hook('UserPromptSubmit'));
    await pumpEventQueue();
    deadline.complete();
    final result = await answer.timeout(const Duration(seconds: 5));
    expect(result['state'], 'running');
    expect(result['childSessionId'], 'new-1');
    expect(result['finalAnswer'], isNull);
    expect(result['note'], contains('session_wait'));
  });

  test('a child that stops for an approval answers blocked', () async {
    insertCaller('caller');
    final answer = await run({
      'prompt': 'Delete the build',
    }, screen: 'claude-code-permission-modal');
    final result = await answer.timeout(const Duration(seconds: 5));
    expect(result['state'], 'blocked');
    expect((result['blockedOn']! as Map)['kind'], 'approvalPrompt');
    expect(result['note'], startsWith('BLOCKED ON A PERSON'));
  });

  test('a child whose process ends answers ended, with its code', () async {
    insertCaller('caller');
    final answer = await run({'prompt': 'Crash'});
    pty.handles.last.finish(3);
    final result = await answer.timeout(const Duration(seconds: 5));
    expect(result['state'], 'ended');
    expect(result['exitCode'], 3);
    expect(result['exitCodeKnown'], isTrue);
  });

  /// Runs [arguments] as [caller] until the child is started, then lets the
  /// bound run out, and answers the child's row.
  Future<Session> childOf(String caller, Map<String, Object?> arguments) async {
    final answer = tools.call('subagent_run', {
      'prompt': 'Review it',
      ...arguments,
    }, caller)!;
    for (var i = 0; i < 20 && pty.handles.isEmpty; i++) {
      await pumpEventQueue();
    }
    deadline.complete();
    final result =
        (await answer.timeout(const Duration(seconds: 5)))!
            as Map<String, Object?>;
    return SessionDao(database).getById(result['childSessionId']! as String)!;
  }

  test('with no project named, the child works in the caller\'s own '
      'directory', () async {
    const directory = EnvironmentPath(
      environmentId: 'local',
      path: '/src/shop/api/packages/cart',
    );
    insertCaller('caller', workingDirectory: directory);
    final child = await childOf('caller', const {});
    expect(child.repositoryId, 'r1');
    expect(child.workingDirectory, directory);
    expect(pty.started.single.workingDirectory, directory.path);
  });

  test(
    'with no project named, the child joins the caller\'s worktree',
    () async {
      const worktree = EnvironmentPath(
        environmentId: 'local',
        path: '/src/shop/worktrees/caller',
      );
      insertCaller('caller', worktree: worktree);
      final child = await childOf('caller', const {});
      expect(child.repositoryId, 'r1');
      expect(child.worktree, worktree);
      expect(pty.started.single.workingDirectory, worktree.path);
    },
  );

  test('a named project still decides where the child runs', () async {
    insertCaller(
      'caller',
      workingDirectory: const EnvironmentPath(
        environmentId: 'local',
        path: '/src/shop/api/packages/cart',
      ),
    );
    await childOf('caller', const {'projectId': 'p1'});
    expect(pty.started.single.workingDirectory, '/src/shop/api');
  });

  test('refuses past the spawn depth, nothing started', () async {
    insertCaller('root');
    insertCaller('child', parent: 'root');
    insertCaller('grandchild', parent: 'child');
    await expectLater(
      tools.call('subagent_run', {
        'projectId': 'p1',
        'prompt': 'go deeper',
      }, 'grandchild'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('levels deep'),
        ),
      ),
    );
    expect(pty.started, isEmpty);
  });

  test(
    'refuses a named mode above the spawn ceiling, nothing started',
    () async {
      insertCaller('caller');
      await expectLater(
        tools.call('subagent_run', {
          'projectId': 'p1',
          'prompt': 'anything',
          'permissionMode': 'bypass',
        }, 'caller'),
        throwsA(isA<ArgumentError>()),
      );
      expect(pty.started, isEmpty);
    },
  );

  group('async mode', () {
    test('subagent_run starts the child and answers at once; its result is '
        'pushed, the child ended once it answers', () async {
      insertCaller('caller');
      final result =
          (await tools
                      .call('subagent_run', {
                        'projectId': 'p1',
                        'prompt': 'Audit the cart',
                        'model': 'claude-haiku',
                        'mode': 'async',
                      }, 'caller')!
                      .timeout(const Duration(seconds: 5)))!
              as Map<String, Object?>;
      expect(result['state'], 'started');
      expect(result['mode'], 'async');
      expect(result['childSessionId'], 'new-1');
      expect(result['note'], contains('End your turn'));
      final watched = delegated.single;
      expect(watched.childId, 'new-1');
      expect(watched.parentId, 'caller');
      expect(watched.model, 'claude-haiku');
      expect(watched.agent, isNotEmpty);
      expect(watched.endOnAnswer, isTrue);
      expect(holds, isEmpty, reason: 'no call waits on an async child');
    });

    test('keepOpen keeps an async child open', () async {
      insertCaller('caller');
      await tools.call('subagent_run', {
        'projectId': 'p1',
        'prompt': 'Look',
        'mode': 'async',
        'keepOpen': true,
      }, 'caller');
      expect(delegated.single.endOnAnswer, isFalse);
    });

    test('open_new_session reports back in async mode, and never ends the '
        'session', () async {
      insertCaller('caller');
      final result =
          (await tools.call('open_new_session', {
                'projectId': 'p1',
                'prompt': 'Write the docs',
                'mode': 'async',
              }, 'caller'))!
              as Map<String, Object?>;
      expect(result['reportsBack'], isTrue);
      expect(delegated.single.childId, result['sessionId']);
      expect(delegated.single.endOnAnswer, isFalse);
    });

    test('open_new_session from a session reports back unless told '
        'detached', () async {
      insertCaller('caller');
      final result =
          (await tools.call('open_new_session', {
                'projectId': 'p1',
                'prompt': 'Write the docs',
              }, 'caller'))!
              as Map<String, Object?>;
      expect(result['reportsBack'], isTrue);
      expect(result['mode'], 'async');
      expect(delegated.single.childId, result['sessionId']);

      final detached =
          (await tools.call('open_new_session', {
                'projectId': 'p1',
                'prompt': 'Leave me be',
                'mode': 'detached',
              }, 'caller'))!
              as Map<String, Object?>;
      expect(detached['reportsBack'], isNull);
      expect(detached['mode'], 'detached');
      expect(delegated, hasLength(1));
    });

    test('open_new_session from no session, or where nothing can push, is '
        'detached by default', () async {
      final result =
          (await tools.call('open_new_session', {'projectId': 'p1'}, null))!
              as Map<String, Object?>;
      expect(result['mode'], 'detached');
      expect(delegated, isEmpty);
    });

    test('subagent_run still waits by default', () async {
      insertCaller('caller');
      final answer = await run({'prompt': 'Audit'});
      expect(delegated, isEmpty);
      expect(holds.first, ('new-1', true));
      deadline.complete();
      expect((await answer)['state'], 'running');
    });

    test('async needs a calling session to report back to', () async {
      await expectLater(
        tools.call('open_new_session', {
          'projectId': 'p1',
          'prompt': 'x',
          'mode': 'async',
        }, null),
        throwsA(isA<ArgumentError>()),
      );
      expect(pty.started, isEmpty);
    });

    test('an unknown mode is refused before anything starts', () async {
      insertCaller('caller');
      await expectLater(
        tools.call('subagent_run', {
          'projectId': 'p1',
          'prompt': 'x',
          'mode': 'later',
        }, 'caller'),
        throwsA(isA<ArgumentError>()),
      );
      expect(pty.started, isEmpty);
    });
  });

  group('report_to_parent', () {
    test("goes to the caller's parent, naming the caller; done unless "
        'told', () async {
      insertCaller('caller');
      insertCaller('child', parent: 'caller');
      final answer =
          (await tools.call('report_to_parent', {
                'text': 'All five fixed.',
              }, 'child'))!
              as Map<String, Object?>;
      final sent = reports.single;
      expect(sent.childId, 'child');
      expect(sent.parentId, 'caller');
      expect(sent.title, 'Orchestrator child');
      expect(sent.agent, isNotEmpty);
      expect(sent.status, ReportStatus.done);
      expect(sent.text, 'All five fixed.');
      expect(answer['parentSessionId'], 'caller');
      expect(answer['status'], 'done');

      await tools.call('report_to_parent', {
        'text': 'Which branch?',
        'status': 'needs_input',
      }, 'child');
      expect(reports.last.status, ReportStatus.needsInput);
    });

    test('a session nobody started is refused in words', () async {
      insertCaller('caller');
      await expectLater(
        tools.call('report_to_parent', {'text': 'Done.'}, 'caller'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('no parent'),
          ),
        ),
      );
      await expectLater(
        tools.call('report_to_parent', {'text': 'Done.'}, null),
        throwsA(isA<StateError>()),
      );
      SessionDao(database).insert(
        Session(
          id: 'fork',
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: 'A fork',
          useWorktree: false,
          status: SessionStatus.running,
          createdAt: t0,
          parentSessionId: 'caller',
          parentLink: SessionLink.fork,
        ),
      );
      await expectLater(
        tools.call('report_to_parent', {'text': 'Done.'}, 'fork'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('forked from'),
          ),
        ),
      );
      expect(reports, isEmpty);
    });

    test('a blank text or an unknown status is refused', () async {
      insertCaller('caller');
      insertCaller('child', parent: 'caller');
      await expectLater(
        tools.call('report_to_parent', {'text': '  '}, 'child'),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        tools.call('report_to_parent', {
          'text': 'x',
          'status': 'finished',
        }, 'child'),
        throwsA(isA<ArgumentError>()),
      );
      expect(reports, isEmpty);
    });
  });

  test('delegation_capabilities lists the agents and models a session can '
      'delegate to, and how deep it may go', () async {
    insertCaller('caller');
    final result =
        (await tools.call('delegation_capabilities', const {}, 'caller'))!
            as Map<String, Object?>;
    final agents = (result['agents']! as List).cast<Map<String, Object?>>();
    final claude = agents.single;
    expect(claude['agentInstallationId'], 'a1');
    expect(claude['cli'], AgentIds.claudeCode);
    expect(claude['name'], isNotEmpty);
    expect(claude['default'], isTrue);
    final models = (claude['models']! as List).cast<Map<String, Object?>>();
    expect(models, isNotEmpty);
    expect(models.first['id'], isNotEmpty);
    expect(result['depth'], 1);
    expect(result['canDelegate'], isTrue);
    expect(result['modes'], ['wait', 'async']);
  });

  test('a blank prompt is refused', () async {
    await expectLater(
      tools.call('subagent_run', {'projectId': 'p1', 'prompt': '  '}, null),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('the bound defaults to ten minutes and is capped', () {
    expect(subagentRunBoundFor(null), const Duration(minutes: 10));
    expect(subagentRunBoundFor(30), const Duration(seconds: 30));
    expect(subagentRunBoundFor(99999), const Duration(minutes: 30));
  });

  test(
    'session_wait answers with the last thing a ready session said',
    () async {
      insertCaller('s1');
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
      pty.handles.last.emit(fixture('claude-code-tui'));
      await pumpEventQueue();
      status.tick();
      answers['s1'] = 'Finished.';
      final sessions = SessionToolSet(
        context,
        prompts: DaemonPromptAnswers(status: status, database: database),
        registry: registry,
        waits: waits,
        answerOf: answerOf,
      );
      final waiting = sessions.call('session_wait', {'sessionId': 's1'}, null)!;
      await pumpEventQueue();
      status.hook(
        AgentHookEvent(
          agent: AgentIds.claudeCode,
          event: 'Stop',
          sessionHeader: 's1',
          receivedAt: DateTime.now().toUtc(),
          body: const {'session_id': 'conv-1', 'hook_event_name': 'Stop'},
        ),
      );
      final result =
          (await waiting.timeout(const Duration(seconds: 5)))!
              as Map<String, Object?>;
      expect(result['state'], anyOf('idle', 'done'));
      expect(result['finalAnswer'], 'Finished.');
    },
  );
}
