import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart'
    show
        AcpLaunchSpec,
        AcpNativeBridge,
        AgentActivityStatus,
        AgentQuestionAnswer,
        PermissionRisk;
import 'package:karmashala_agent_status/karmashala_agent_status.dart'
    show SessionPromptRefusal;
import 'package:karmashala_acp/karmashala_acp.dart';
import 'package:karmashala_host/src/acp/acp_login_required.dart';
import 'package:karmashala_host/src/acp/acp_native_bridge.dart';
import 'package:karmashala_host/src/acp/acp_session_runtime.dart';
import 'package:karmashala_host/src/acp/acp_transport.dart';
import 'package:karmashala_host/src/acp/claude/claude_stream_json_bridge.dart'
    show ClaudeStreamJsonBridge;
import 'package:karmashala_host/src/sessions/session_message_transcripts.dart'
    show SessionMessageTranscriptSource;
import 'package:karmashala_host/src/acp/acp_usage_limit.dart'
    show kProtocolUsageLimitReason, usageLimitResetIn;
import 'package:karmashala_host_protocol/protocol.dart'
    show SessionEndedWithoutCode, SessionExited;
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import '../acp_fixture.dart';
import 'fake_claude.dart';

const _spec = AcpLaunchSpec(
  nativeBridge: AcpNativeBridge.claudeStreamJson,
  modeNames: {
    PermissionRisk.readOnly: ['plan'],
    PermissionRisk.ask: ['default'],
    PermissionRisk.acceptEdits: ['acceptEdits'],
    PermissionRisk.autoRun: ['bypassPermissions'],
    PermissionRisk.bypass: ['bypassPermissions'],
  },
);

/// Claude Code's stream-json protocol, translated to ACP in-process, driven
/// through the real session runtime against an in-memory `claude`.
void main() {
  late AppDatabase database;
  late Directory temp;
  late RecordingHost host;

  /// What the bridge said to the runtime, decoded, in order.
  late List<Json> wire;

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    temp = Directory.systemTemp.createTempSync('claude_bridge_test');
    host = RecordingHost();
    wire = [];
  });

  tearDown(() {
    database.close();
    temp.deleteSync(recursive: true);
  });

  List<SessionMessage> rows() => SessionMessageDao(database).listAfter('s1');

  List<Json> tools() => [
    for (final row in rows())
      if (row.toolJson != null) jsonDecode(row.toolJson!) as Json,
  ];

  /// The `session/update`s of [kind] the bridge sent.
  List<Json> updates(String kind) => [
    for (final m in wire)
      if (m['method'] == 'session/update' &&
          ((m['params'] as Json)['update'] as Json)['sessionUpdate'] == kind)
        (m['params'] as Json)['update'] as Json,
  ];

  AcpSessionRuntime runtime(
    FakeClaudeMachine machine, {
    PermissionRisk? risk,
    String? resumeSessionId,
    String? mcpUrl,
    Duration? interruptPatience,
  }) {
    var ids = 0;
    return AcpSessionRuntime(
      id: 'karmashala_s1',
      sessionId: 's1',
      agentId: 'claude-acp',
      agentName: 'Claude',
      spec: _spec,
      workingDirectory: temp.path,
      spawn: () async => _tapped(
        bridgedAcpTransport(
          _spec,
          await machine.spawn(),
          bridges: {
            AcpNativeBridge.claudeStreamJson: (raw) => ClaudeStreamJsonBridge(
              raw,
              interruptPatience:
                  interruptPatience ?? const Duration(seconds: 5),
            ),
          },
        ),
        wire,
      ),
      messages: SessionMessageDao(database),
      usage: SessionUsageDao(database),
      host: host,
      mcpUrl: mcpUrl,
      risk: risk,
      resumeSessionId: resumeSessionId,
      newId: () => 'm${++ids}',
      coalesce: const Duration(milliseconds: 10),
      stopPatience: const Duration(milliseconds: 300),
      startPatience: const Duration(seconds: 5),
    );
  }

  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 400 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(condition(), isTrue, reason: 'condition never held');
  }

  group('starting', () {
    test('initialize reports Claude Code, its version and its login; '
        'session/new is a fresh process on a session id of its own, with '
        "Karmashala's MCP server, the four modes and the models", () async {
      final machine = FakeClaudeMachine();
      final rt = runtime(
        machine,
        risk: PermissionRisk.acceptEdits,
        mcpUrl: 'http://127.0.0.1:9/mcp/tok',
      );
      final outcome = await rt.start();

      final init = wire.firstWhere((m) => m['id'] == 1)['result'] as Json;
      expect(init['protocolVersion'], 1);
      expect(init['agentInfo'], containsPair('version', '2.1.287'));
      expect(init['agentInfo'], containsPair('name', 'claude-code'));
      final caps = init['agentCapabilities'] as Json;
      expect(caps['loadSession'], isTrue);
      expect((caps['promptCapabilities'] as Json)['image'], isTrue);
      final auth = (init['authMethods'] as List).single as Json;
      expect(auth['type'], 'terminal');
      expect(auth['args'], ['auth', 'login']);
      // The account's address never crosses.
      expect(jsonEncode(init), isNot(contains('someone@example.com')));

      // The launcher's process answered initialize; the conversation is a
      // relaunch carrying the id session/new answered with.
      final conversation = machine.current;
      expect(conversation.args.first, '--session-id');
      expect(outcome.agentSessionId, conversation.args[1]);
      expect(outcome.resumed, isFalse);
      expect(machine.launched.first.stdinClosed, isTrue);

      final servers = conversation.controls('mcp_set_servers').single;
      expect(servers['servers'], {
        'karmashala': {
          'type': 'http',
          'url': 'http://127.0.0.1:9/mcp/tok',
          'headers': <String, Object?>{},
        },
      });

      final modes = rt.modes!;
      expect(modes.availableModes.map((m) => m.id), [
        'default',
        'acceptEdits',
        'plan',
        'bypassPermissions',
      ]);
      // The rung's mode was set over the control channel.
      expect(modes.currentModeId, 'acceptEdits');
      expect(
        conversation.controls('set_permission_mode').single['mode'],
        'acceptEdits',
      );

      final model = rt.configOptions!.options.single;
      expect(model.id, 'model');
      expect(model.currentValue, 'default');
      expect(model.choices.map((c) => c.value), ['default', 'sonnet', 'haiku']);
      await rt.stop();
    });

    test('a person not logged in is asked to log in, in words', () async {
      final rt = runtime(FakeClaudeMachine(loggedIn: false));
      await expectLater(rt.start(), throwsA(isA<AcpLoginRequired>()));
    });

    test('session/load resumes the conversation by id in a process of its '
        'own', () async {
      final machine = FakeClaudeMachine(conversations: {'conv-1'});
      final rt = runtime(machine, resumeSessionId: 'conv-1');
      final outcome = await rt.start();
      expect(outcome.resumed, isTrue);
      expect(outcome.agentSessionId, 'conv-1');
      expect(machine.current.args, ['--resume', 'conv-1']);
      await rt.stop();
    });

    test('a conversation Claude no longer holds (an old adapter session '
        'whose transcript is gone) starts fresh and says so', () async {
      final machine = FakeClaudeMachine();
      final rt = runtime(machine, resumeSessionId: 'gone');
      final outcome = await rt.start();
      expect(outcome.resumed, isFalse);
      expect(outcome.notices, contains(contains('no longer holds')));
      expect(machine.launched.map((c) => c.args.take(1).join()), [
        '',
        '--version',
        '--resume',
        '--session-id',
      ]);
      expect(machine.current.exited, isFalse);
      await rt.stop();
    });
  });

  group('a turn', () {
    test('streamed text and thinking become one agent row, the full message '
        'is not written twice, and the result ends the turn with its usage '
        'and cost', () async {
      final machine = FakeClaudeMachine(
        turns: [
          (c, user) async {
            c.init();
            c.streamText('msg1', ['Let me ', 'think.'], thinking: true);
            c.streamText('msg1', ['Hello', ' there.']);
            c.assistant('msg1', [
              {'type': 'thinking', 'thinking': 'Let me think.'},
              {'type': 'text', 'text': 'Hello there.'},
            ]);
            c.result();
          },
        ],
      );
      final rt = runtime(machine);
      await rt.start();
      await rt.send('Say hello');
      expect(await rt.awaitTurn(), StopReason.endTurn);

      final user = machine.current.received.firstWhere(
        (m) => m['type'] == 'user',
      );
      expect((user['message'] as Json)['content'], [
        {'type': 'text', 'text': 'Say hello'},
      ]);
      final agent = rows().where((r) => r.role == SessionMessageRole.agent);
      expect(agent.single.text, 'Hello there.');
      expect(agent.single.thinking, 'Let me think.');

      final usage = host.usage.last;
      expect(usage.contextUsed, 10 + 100 + 1000 + 5);
      expect(usage.contextSize, 200000);
      expect(usage.costAmount, 0.25);
      expect(usage.costCurrency, 'USD');
      expect(
        (updates('usage_update').last['_meta'] as Json)['claudeCode'],
        containsPair('durationMs', 1200),
      );
      await rt.stop();
    });

    test(
      'tool calls carry their kind, title, input and locations; Edit, '
      'Write and MultiEdit carry diffs; results complete or fail them',
      () async {
        final machine = FakeClaudeMachine(
          turns: [
            (c, user) async {
              c.toolUse('t1', 'Read', {'file_path': '/w/a.txt', 'offset': 3});
              c.toolResult('t1', '1\tbanana');
              c.toolUse('t2', 'Bash', {
                'command': 'echo hi',
                'description': 'Say hi',
              });
              c.toolResult('t2', 'hi');
              c.toolUse('t3', 'Edit', {
                'file_path': '/w/a.txt',
                'old_string': 'banana',
                'new_string': 'apple',
              });
              c.toolResult('t3', 'updated');
              c.toolUse('t4', 'Write', {
                'file_path': '/w/b.txt',
                'content': 'x',
              });
              c.toolResult('t4', 'denied', isError: true);
              c.toolUse('t5', 'MultiEdit', {
                'file_path': '/w/a.txt',
                'edits': [
                  {'old_string': 'a', 'new_string': 'b'},
                  {'old_string': 'c', 'new_string': 'd'},
                ],
              });
              c.toolResult('t5', [
                {'type': 'text', 'text': 'two edits'},
              ]);
              c.toolUse('t6', 'Grep', {'pattern': 'TODO'});
              c.toolResult('t6', 'none');
              c.toolUse('t7', 'mcp__karmashala__list_sessions', {});
              c.toolResult('t7', '[]');
              c.result();
            },
          ],
        );
        final rt = runtime(machine);
        await rt.start();
        await rt.send('Work');
        await rt.awaitTurn();

        final calls = {for (final t in tools()) t['toolCallId']: t};
        expect(calls['t1'], containsPair('kind', 'read'));
        expect(calls['t1'], containsPair('status', 'completed'));
        expect(calls['t1']!['title'], 'Read /w/a.txt');
        expect(calls['t1']!['locations'], [
          {'path': '/w/a.txt', 'line': 3},
        ]);
        expect(calls['t1']!['content'], [
          {
            'type': 'content',
            'content': {'type': 'text', 'text': '1\tbanana'},
          },
        ]);
        expect(calls['t2'], containsPair('kind', 'execute'));
        expect(calls['t2']!['title'], 'echo hi');
        expect(calls['t2']!['rawInput'], {
          'command': 'echo hi',
          'description': 'Say hi',
        });
        expect(calls['t3'], containsPair('kind', 'edit'));
        expect(calls['t3']!['content'], [
          {
            'type': 'diff',
            'path': '/w/a.txt',
            'oldText': 'banana',
            'newText': 'apple',
          },
        ]);
        expect(calls['t4']!['content'], [
          {'type': 'diff', 'path': '/w/b.txt', 'oldText': null, 'newText': 'x'},
          {
            'type': 'content',
            'content': {'type': 'text', 'text': 'denied'},
          },
        ]);
        expect(calls['t4'], containsPair('status', 'failed'));
        expect((calls['t5']!['content'] as List).take(2), [
          {'type': 'diff', 'path': '/w/a.txt', 'oldText': 'a', 'newText': 'b'},
          {'type': 'diff', 'path': '/w/a.txt', 'oldText': 'c', 'newText': 'd'},
        ]);
        expect(calls['t6'], containsPair('kind', 'search'));
        expect(calls['t7'], containsPair('kind', 'other'));
        // The paths an edit touches reach the checkpoint.
        expect(host.touched, containsAll(['/w/a.txt', '/w/b.txt']));
        // What ACP has no field for rides in _meta.
        final opened = updates(
          'tool_call',
        ).firstWhere((u) => u['toolCallId'] == 't7');
        expect((opened['_meta'] as Json)['claudeCode'], {
          'toolName': 'mcp__karmashala__list_sessions',
        });
        await rt.stop();
      },
    );

    test('TodoWrite, and the TaskCreate/TaskUpdate tools that replaced it, '
        'become the plan rather than tool rows', () async {
      final machine = FakeClaudeMachine(
        turns: [
          (c, user) async {
            c.toolUse('td', 'TodoWrite', {
              'todos': [
                {'content': 'One', 'status': 'completed', 'activeForm': 'x'},
                {'content': 'Two', 'status': 'in_progress', 'activeForm': 'y'},
              ],
            });
            c.toolResult('td', 'ok');
            c.result();
          },
          (c, user) async {
            c.toolUse('k1', 'TaskCreate', {'subject': 'A', 'description': ''});
            c.toolResult(
              'k1',
              'Task #1 created successfully: A',
              toolUseResult: {
                'task': {'id': '1', 'subject': 'A'},
              },
            );
            c.toolUse('k2', 'TaskCreate', {'subject': 'B', 'description': ''});
            c.toolResult(
              'k2',
              'Task #2 created successfully: B',
              toolUseResult: {
                'task': {'id': '2', 'subject': 'B'},
              },
            );
            c.toolUse('k3', 'TaskUpdate', {
              'taskId': '1',
              'status': 'in_progress',
            });
            c.toolResult('k3', 'Updated task #1 status');
            c.result();
          },
        ],
      );
      final rt = runtime(machine);
      await rt.start();
      await rt.send('Plan');
      await rt.awaitTurn();
      Json plan() =>
          jsonDecode(rows().lastWhere((r) => r.planJson != null).planJson!)
              as Json;
      expect(plan()['entries'], [
        {'content': 'One', 'priority': 'medium', 'status': 'completed'},
        {'content': 'Two', 'priority': 'medium', 'status': 'in_progress'},
      ]);
      await rt.send('Tasks');
      await rt.awaitTurn();
      expect(plan()['entries'], [
        {'content': 'A', 'priority': 'medium', 'status': 'in_progress'},
        {'content': 'B', 'priority': 'medium', 'status': 'pending'},
      ]);
      expect(tools(), isEmpty);
      await rt.stop();
    });

    test("a subagent's work shows on its Task call: its text, its own tool "
        'calls tied to the parent in _meta, and its end', () async {
      final machine = FakeClaudeMachine(
        turns: [
          (c, user) async {
            c.toolUse('ag', 'Agent', {
              'description': 'List files',
              'prompt': 'list them',
              'subagent_type': 'Explore',
            });
            c.system('task_started', {
              'task_id': 'task1',
              'tool_use_id': 'ag',
              'description': 'List files',
              'subagent_type': 'Explore',
            });
            c.toolResult('ag', 'Async agent launched successfully.');
            c.toolUse(
              'sb',
              'Bash',
              {'command': 'ls'},
              parentToolUseId: 'ag',
              message: 'sub1',
            );
            c.toolResult('sb', 'a.txt', parentToolUseId: 'ag');
            c.assistant('sub2', [
              {'type': 'text', 'text': 'One file.'},
            ], parentToolUseId: 'ag');
            c.system('task_notification', {
              'task_id': 'task1',
              'tool_use_id': 'ag',
              'status': 'completed',
              'summary': 'One file.',
            });
            c.result();
          },
        ],
      );
      final rt = runtime(machine);
      await rt.start();
      await rt.send('Delegate');
      await rt.awaitTurn();
      final calls = {for (final t in tools()) t['toolCallId']: t};
      expect(calls['ag'], containsPair('kind', 'think'));
      expect(calls['ag']!['title'], 'List files');
      expect(calls['ag'], containsPair('status', 'completed'));
      expect(jsonEncode(calls['ag']!['content']), contains('One file.'));
      expect(calls['sb'], containsPair('kind', 'execute'));
      final sub = updates(
        'tool_call',
      ).firstWhere((u) => u['toolCallId'] == 'sb');
      expect(
        (sub['_meta'] as Json)['claudeCode'],
        containsPair('parentToolUseId', 'ag'),
      );
      final started = updates(
        'tool_call_update',
      ).firstWhere((u) => u['toolCallId'] == 'ag' && u['_meta'] != null);
      expect(
        ((started['_meta'] as Json)['claudeCode'] as Json)['task'],
        containsPair('subagentType', 'Explore'),
      );
      // The subagent's words never reach the main reply.
      expect(
        rows().where((r) => r.role == SessionMessageRole.agent && r.text != ''),
        isEmpty,
      );
      await rt.stop();
    });

    Json limit(String status, {int resetsAt = 1791127800}) => {
      'status': status,
      'resetsAt': resetsAt,
      'rateLimitType': 'five_hour',
      'overageStatus': 'rejected',
      'isUsingOverage': false,
      'unifiedWindows': {
        'five_hour': {'utilization': 0.42, 'resetsAt': resetsAt},
      },
    };

    test('rate-limit events are usage updates carrying the limits and their '
        'reset in _meta', () async {
      final machine = FakeClaudeMachine(
        turns: [
          (c, user) async {
            c.assistant('m1', [
              {'type': 'text', 'text': 'One.'},
            ]);
            // Before any context size is known: held for the next update.
            c.emit({
              'type': 'rate_limit_event',
              'rate_limit_info': limit('allowed'),
            });
            c.result();
          },
          (c, user) async {
            c.emit({
              'type': 'rate_limit_event',
              'rate_limit_info': limit('allowed_warning'),
            });
            c.result();
          },
        ],
      );
      final rt = runtime(machine);
      await rt.start();
      await rt.send('One');
      await rt.awaitTurn();
      Json? limitOf(Json update) =>
          ((update['_meta'] as Json?)?['claudeCode'] as Json?)?['rateLimit']
              as Json?;
      expect(limitOf(updates('usage_update').last), limit('allowed'));
      final before = updates('usage_update').length;
      await rt.send('Two');
      await rt.awaitTurn();
      final passed = updates('usage_update').skip(before).first;
      expect(limitOf(passed), limit('allowed_warning'));
      // The context it reports is the last one known, not zero.
      expect(passed['size'], 200000);
      expect(passed['used'], greaterThan(0));
      await rt.stop();
    });

    test('a limit Claude reports hit ends the turn as a usage limit, with '
        'its reset where the queue reads it', () async {
      final machine = FakeClaudeMachine(
        turns: [
          (c, user) async {
            c.emit({
              'type': 'rate_limit_event',
              'rate_limit_info': limit('rejected'),
            });
            c.result(
              subtype: 'error_during_execution',
              isError: true,
              text: null,
              stopReason: null,
            );
          },
        ],
      );
      final rt = runtime(machine);
      await rt.start();
      await rt.send('Hi');
      await rt.awaitTurn();
      final failed = host.statuses.last;
      expect(failed.status, AgentActivityStatus.failed);
      expect(failed.failureReason, kProtocolUsageLimitReason);
      expect(
        usageLimitResetIn(failed.evidence, DateTime.utc(2026, 10, 4)),
        DateTime.fromMillisecondsSinceEpoch(1791127800 * 1000, isUtc: true),
      );
      await rt.stop();
    });

    test('a compaction is said in the chat as a terminal session says it: '
        "Claude's summary on a row marked as the boundary", () async {
      final machine = FakeClaudeMachine(
        turns: [
          (c, user) async {
            c.system('status', {'status': 'compacting'});
            c.system('compact_boundary', {
              'compact_metadata': {
                'trigger': 'manual',
                'pre_tokens': 31249,
                'post_tokens': 2640,
              },
            });
            c.emit({
              'type': 'user',
              'message': {
                'role': 'user',
                'content': 'This session is being continued. Summary: bananas.',
              },
            });
            c.emit({
              'type': 'user',
              'message': {
                'role': 'user',
                'content':
                    '<local-command-stdout>Compacted </local-command-stdout>',
              },
              'isReplay': true,
            });
            c.result();
          },
        ],
      );
      final rt = runtime(machine);
      await rt.start();
      await rt.send('/compact');
      await rt.awaitTurn();
      final projected = [
        for (final row in rows()) SessionMessageTranscriptSource.project(row),
      ];
      final boundary = projected.where((m) => m.compaction != null).single;
      expect(boundary.compaction!.trigger, 'manual');
      expect(boundary.text, contains('Summary: bananas.'));
      expect(projected.any((m) => m.text.contains('local-command')), isFalse);
      await rt.stop();
    });

    test('a failed turn is an error with its words; a usage limit reads as '
        'one', () async {
      final machine = FakeClaudeMachine(
        turns: [
          (c, user) async => c.result(
            isError: true,
            text: "You've hit your usage limit · resets in 2h",
            stopReason: null,
          ),
        ],
      );
      final rt = runtime(machine);
      await rt.start();
      await rt.send('Hi');
      await rt.awaitTurn();
      final last = host.statuses.last;
      expect(last.status, AgentActivityStatus.failed);
      expect(last.failureReason, kProtocolUsageLimitReason);
      await rt.stop();
    });
  });

  group('permissions', () {
    Json writeInput() => {'file_path': '/w/out.txt', 'content': 'x'};
    const suggestion = {
      'type': 'setMode',
      'mode': 'acceptEdits',
      'destination': 'session',
    };

    test(
      'a can_use_tool becomes session/request_permission with allow, '
      'always allow and reject; allowing hands Claude the input back',
      () async {
        final answered = Completer<Json>();
        final machine = FakeClaudeMachine(
          turns: [
            (c, user) async {
              c.toolUse('w1', 'Write', writeInput());
              answered.complete(
                await c.askPermission(
                  'w1',
                  'Write',
                  writeInput(),
                  suggestions: [suggestion],
                ),
              );
              c.toolResult('w1', 'written');
              c.result();
            },
          ],
        );
        final rt = runtime(machine);
        await rt.start();
        await rt.send('Write it');
        await until(() => rt.hasOpenPermission);
        expect(rt.pendingToolCallId, 'w1');
        final asked = wire.firstWhere(
          (m) => m['method'] == 'session/request_permission',
        );
        final options = (asked['params'] as Json)['options'] as List;
        expect(options.map((o) => (o as Json)['kind']), [
          'allow_once',
          'allow_always',
          'reject_once',
        ]);
        final toolCall = (asked['params'] as Json)['toolCall'] as Json;
        expect(toolCall['kind'], 'edit');
        expect(toolCall['content'], [
          {
            'type': 'diff',
            'path': '/w/out.txt',
            'oldText': null,
            'newText': 'x',
          },
        ]);
        await rt.answerPermission(approve: true);
        expect(await answered.future, {
          'behavior': 'allow',
          'updatedInput': writeInput(),
        });
        await rt.awaitTurn();
        await rt.stop();
      },
    );

    test('a denied permission is a deny with a message', () async {
      final answered = Completer<Json>();
      final machine = FakeClaudeMachine(
        turns: [
          (c, user) async {
            c.toolUse('w1', 'Write', writeInput());
            answered.complete(
              await c.askPermission('w1', 'Write', writeInput()),
            );
            c.toolResult('w1', 'not now', isError: true);
            c.result();
          },
        ],
      );
      final rt = runtime(machine);
      await rt.start();
      await rt.send('Write it');
      await until(() => rt.hasOpenPermission);
      final answer = await rt.answerPermission(approve: false);
      expect(answer.granted, isFalse);
      final response = await answered.future;
      expect(response['behavior'], 'deny');
      expect(response['message'], isA<String>());
      expect(response.containsKey('interrupt'), isFalse);
      await rt.awaitTurn();
      expect(tools().single, containsPair('status', 'failed'));
      await rt.stop();
    });

    test(
      'allow-always hands Claude its own suggested permission update',
      () async {
        final answered = Completer<Json>();
        final machine = FakeClaudeMachine(
          turns: [
            (c, user) async {
              c.toolUse('w1', 'Write', writeInput());
              answered.complete(
                await c.askPermission(
                  'w1',
                  'Write',
                  writeInput(),
                  suggestions: [suggestion],
                ),
              );
              c.result();
            },
          ],
        );
        // A client choosing "always" directly: the runtime answers once only.
        final bridged = bridgedAcpTransport(_spec, await machine.spawn());
        final client = AcpAgentClient(
          AcpPeer(bridged.output, bridged.input),
          handler: _Choosing((o) => o.kind == PermissionOptionKind.allowAlways),
        );
        await client.initialize(
          clientInfo: const ClientInfo(name: 't', version: '0'),
        );
        final session = await client.newSession(cwd: temp.path);
        final turn = client.prompt(session.sessionId, [
          ContentBlock.text('Go'),
        ]);
        expect(await answered.future, {
          'behavior': 'allow',
          'updatedInput': writeInput(),
          'updatedPermissions': [suggestion],
        });
        expect(await turn, StopReason.endTurn);
        await client.close();
      },
    );

    test('ExitPlanMode asks to leave plan mode, and the choice sets the '
        'mode', () async {
      final answered = Completer<Json>();
      final machine = FakeClaudeMachine(
        turns: [
          (c, user) async {
            c.toolUse('ep', 'ExitPlanMode', {'plan': '1. Do it'});
            answered.complete(
              await c.askPermission('ep', 'ExitPlanMode', {'plan': '1. Do it'}),
            );
            c.result();
          },
        ],
      );
      final rt = runtime(machine, risk: PermissionRisk.readOnly);
      await rt.start();
      expect(rt.modes!.currentModeId, 'plan');
      await rt.send('Plan it');
      await until(() => rt.hasOpenPermission);
      final asked = wire.firstWhere(
        (m) => m['method'] == 'session/request_permission',
      );
      final params = asked['params'] as Json;
      expect((params['toolCall'] as Json)['kind'], 'switch_mode');
      expect(
        [for (final o in params['options'] as List) (o as Json)['optionId']],
        ['acceptEdits', 'default', 'plan'],
      );
      // The runtime allows once: plan mode is left for "ask every time".
      await rt.answerPermission(approve: true);
      final response = await answered.future;
      expect(response['behavior'], 'allow');
      expect(response['updatedPermissions'], [
        {'type': 'setMode', 'mode': 'default', 'destination': 'session'},
      ]);
      await rt.awaitTurn();
      await until(() => rt.modes!.currentModeId == 'default');
      await rt.stop();
    });

    Json question({
      String text = 'Which fruit?',
      List<String> choices = const ['Apple', 'Pear'],
      bool multiSelect = false,
    }) => {
      'question': text,
      'header': 'Fruit',
      'options': [
        for (final choice in choices)
          {'label': choice, 'description': 'A $choice'},
      ],
      'multiSelect': multiSelect,
    };

    /// A turn asking [questions], completing [answered] with Claude's reply.
    FakeClaudeTurn asking(List<Json> questions, Completer<Json> answered) =>
        (c, user) async {
          final input = {'questions': questions};
          c.toolUse('q', 'AskUserQuestion', input);
          answered.complete(
            await c.askPermission('q', 'AskUserQuestion', input),
          );
          c.result();
        };

    test('every question goes in one request, carried with its choices and '
        'whether several may be picked; the runtime holds them as an open '
        'question', () async {
      final answered = Completer<Json>();
      final machine = FakeClaudeMachine(
        turns: [
          asking([
            question(),
            question(
              text: 'Which fruits?',
              choices: ['Apple', 'Pear', 'Plum'],
              multiSelect: true,
            ),
          ], answered),
        ],
      );
      final rt = runtime(machine);
      await rt.start();
      await rt.send('Ask me');
      await until(() => rt.hasOpenPermission);
      final asks = wire
          .where((m) => m['method'] == 'session/request_permission')
          .toList();
      expect(asks, hasLength(1));
      final toolCall = (asks.single['params'] as Json)['toolCall'] as Json;
      final carried =
          ((toolCall['_meta'] as Json)['karmashala'] as Json)['questions']
              as List;
      expect(carried, hasLength(2));
      expect((carried[1] as Json)['multiSelect'], isTrue);
      final open = rt.openQuestion!;
      expect(open.toolUseId, 'q');
      expect(open.questions.map((q) => q.multiSelect), [false, true]);

      await rt.answerQuestion(
        toolUseId: 'q',
        answers: const [
          AgentQuestionAnswer.option(1),
          AgentQuestionAnswer.options([0, 2]),
        ],
      );
      final response = await answered.future;
      expect(response['behavior'], 'allow');
      expect((response['updatedInput'] as Json)['answers'], {
        'Which fruit?': 'Pear',
        'Which fruits?': 'Apple, Plum',
      });
      expect(rt.openQuestion, isNull);
      await rt.awaitTurn();
      await rt.stop();
    });

    test('an answer in the person\'s own words goes back as written', () async {
      final answered = Completer<Json>();
      final machine = FakeClaudeMachine(
        turns: [
          asking([question()], answered),
        ],
      );
      final rt = runtime(machine);
      await rt.start();
      await rt.send('Ask me');
      await until(() => rt.hasOpenPermission);
      await rt.answerQuestion(
        toolUseId: 'q',
        answers: const [AgentQuestionAnswer.text('Mango')],
      );
      final response = await answered.future;
      expect((response['updatedInput'] as Json)['answers'], {
        'Which fruit?': 'Mango',
      });
      await rt.awaitTurn();
      await rt.stop();
    });

    test('an answer for another question, or one that does not fit, is '
        'refused with nothing sent', () async {
      final answered = Completer<Json>();
      final machine = FakeClaudeMachine(
        turns: [
          asking([question()], answered),
        ],
      );
      final rt = runtime(machine);
      await rt.start();
      await rt.send('Ask me');
      await until(() => rt.hasOpenPermission);
      await expectLater(
        rt.answerQuestion(
          toolUseId: 'other',
          answers: const [AgentQuestionAnswer.option(0)],
        ),
        throwsA(isA<SessionPromptRefusal>()),
      );
      await expectLater(
        rt.answerQuestion(
          toolUseId: 'q',
          answers: const [AgentQuestionAnswer.option(5)],
        ),
        throwsA(isA<SessionPromptRefusal>()),
      );
      expect(answered.isCompleted, isFalse);
      await rt.answerQuestion(
        toolUseId: 'q',
        answers: const [AgentQuestionAnswer.option(0)],
      );
      expect((await answered.future)['behavior'], 'allow');
      await rt.awaitTurn();
      await rt.stop();
    });

    test('a question offers "Send answer" and "Answer in my reply"; '
        'answering in the reply declines it and puts the question in the '
        'chat', () async {
      final answered = Completer<Json>();
      final machine = FakeClaudeMachine(
        turns: [
          asking([question(multiSelect: true)], answered),
        ],
      );
      final rt = runtime(machine);
      await rt.start();
      await rt.send('Ask me');
      await until(() => rt.hasOpenPermission);
      final params =
          wire.firstWhere(
                (m) => m['method'] == 'session/request_permission',
              )['params']
              as Json;
      expect(
        [for (final o in params['options'] as List) (o as Json)['name']],
        ['Send answer', 'Answer in my reply'],
      );
      await rt.answerPermission(approve: false);
      final response = await answered.future;
      expect(response['behavior'], 'deny');
      expect(response['message'], contains('next message'));
      await rt.awaitTurn();
      final said = rows()
          .where((r) => r.role == SessionMessageRole.agent)
          .map((r) => r.text)
          .join('\n');
      expect(said, contains('Which fruit?'));
      expect(said, contains('Apple'));
      await rt.stop();
    });

    test('a question with no choices, or one asked where nobody is asked '
        '(bypass), is declined and shown in the chat', () async {
      for (final (choices, risk) in [
        (const <String>[], PermissionRisk.ask),
        (const ['Apple', 'Pear'], PermissionRisk.bypass),
      ]) {
        wire.clear();
        final answered = Completer<Json>();
        final machine = FakeClaudeMachine(
          turns: [
            asking([question(text: 'Your name?', choices: choices)], answered),
          ],
        );
        final rt = runtime(machine, risk: risk);
        await rt.start();
        await rt.send('Ask me');
        final response = await answered.future;
        expect(response['behavior'], 'deny');
        expect(
          wire.where((m) => m['method'] == 'session/request_permission'),
          isEmpty,
        );
        await rt.awaitTurn();
        expect(
          rows().where((r) => r.text.contains('Your name?')),
          isNotEmpty,
          reason: '$risk',
        );
        await rt.stop();
        database.execute('DELETE FROM session_messages');
      }
    });
  });

  group('control', () {
    test('a Claude that does not end the turn after the interrupt is ended; '
        'the turn ends cancelled, and the next prompt resumes the '
        'conversation in a new process with its mode and model', () async {
      final machine = FakeClaudeMachine(
        ignoreInterrupt: true,
        turns: [
          (c, user) async => c.streamText('m1', ['stuck ']),
          (c, user) async {
            c.assistant('m2', [
              {'type': 'text', 'text': 'Back.'},
            ]);
            c.result();
          },
        ],
      );
      final rt = runtime(
        machine,
        interruptPatience: const Duration(milliseconds: 100),
      );
      await rt.start();
      await rt.setMode('plan');
      await rt.setConfigOption('model', 'sonnet');
      final first = machine.current;
      await rt.send('Hang');
      await until(() => rows().any((r) => r.text.contains('stuck')));
      rt.cancel();
      expect(await rt.awaitTurn(), StopReason.cancelled);
      expect(first.killed, isTrue);
      expect(rt.lifecycle.hasEnded, isFalse, reason: 'the session lives on');
      expect(host.statuses.last.status, AgentActivityStatus.idle);

      await rt.send('Again');
      expect(await rt.awaitTurn(), StopReason.endTurn);
      final second = machine.current;
      expect(second, isNot(same(first)));
      expect(second.args, ['--resume', rt.agentSessionId]);
      expect(second.controls('set_permission_mode').single['mode'], 'plan');
      expect(second.controls('set_model').single['model'], 'sonnet');
      expect(rows().any((r) => r.text == 'Back.'), isTrue);
      await rt.stop();
    });

    test('cancel interrupts the turn mid-stream; the turn ends cancelled and '
        'the next one runs in the same process', () async {
      final machine = FakeClaudeMachine(
        turns: [
          (c, user) async => c.streamText('m1', ['one ', 'two ']),
          (c, user) async {
            c.assistant('m2', [
              {'type': 'text', 'text': 'Again.'},
            ]);
            c.result();
          },
        ],
      );
      final rt = runtime(machine);
      await rt.start();
      await rt.send('Count');
      await until(() => rows().any((r) => r.text.contains('two')));
      rt.cancel();
      expect(await rt.awaitTurn(), StopReason.cancelled);
      expect(machine.current.controls('interrupt'), hasLength(1));
      // "[Request interrupted by user]" is Claude's echo, not a reply.
      expect(rows().any((r) => r.text.contains('interrupted')), isFalse);
      await rt.send('Again');
      expect(await rt.awaitTurn(), StopReason.endTurn);
      expect(
        machine.launched.where((c) => c.args.contains('--session-id')),
        hasLength(1),
      );
      await rt.stop();
    });

    test(
      'cancel while a permission is open denies it with interrupt',
      () async {
        final answered = Completer<Json>();
        final machine = FakeClaudeMachine(
          turns: [
            (c, user) async {
              c.toolUse('w1', 'Write', {'file_path': '/w/a', 'content': ''});
              answered.complete(
                await c.askPermission('w1', 'Write', {
                  'file_path': '/w/a',
                  'content': '',
                }),
              );
            },
          ],
        );
        final rt = runtime(machine);
        await rt.start();
        await rt.send('Write');
        await until(() => rt.hasOpenPermission);
        rt.cancel();
        final response = await answered.future;
        expect(response['behavior'], 'deny');
        expect(response['interrupt'], isTrue);
        expect(await rt.awaitTurn(), StopReason.cancelled);
        await rt.stop();
      },
    );

    test('modes are set and followed over the control channel', () async {
      final machine = FakeClaudeMachine(
        turns: [
          (c, user) async {
            // Claude leaving plan mode of itself.
            c.system('status', {'status': null, 'permissionMode': 'default'});
            c.result();
          },
        ],
      );
      final rt = runtime(machine);
      await rt.start();
      await rt.setMode('plan');
      expect(
        machine.current.controls('set_permission_mode').last['mode'],
        'plan',
      );
      expect(rt.modes!.currentModeId, 'plan');
      await rt.send('Go');
      await rt.awaitTurn();
      await until(() => rt.modes!.currentModeId == 'default');
      await rt.stop();
    });

    test('the model is a config option set with set_model, and follows the '
        'model Claude reports', () async {
      final machine = FakeClaudeMachine(
        turns: [
          (c, user) async {
            c.init(model: 'claude-haiku-4-5-20251001');
            c.result();
          },
        ],
      );
      final rt = runtime(machine);
      await rt.start();
      await rt.setConfigOption('model', 'sonnet');
      expect(machine.current.controls('set_model').single['model'], 'sonnet');
      expect(rt.configOptions!.options.single.currentValue, 'sonnet');
      await rt.send('Go');
      await rt.awaitTurn();
      await until(
        () => rt.configOptions!.options.single.currentValue == 'haiku',
      );
      await rt.stop();
    });
  });

  group('the process', () {
    test('dying mid-turn fails the turn with its stderr and ends the '
        'session with its code', () async {
      final machine = FakeClaudeMachine(
        turns: [
          (c, user) async {
            c.streamText('m1', ['Working']);
            c.stderr('panic: out of memory');
            c.die(3);
          },
        ],
      );
      final rt = runtime(machine);
      await rt.start();
      await rt.send('Go');
      await rt.awaitTurn();
      final failed = host.statuses.lastWhere(
        (s) => s.status == AgentActivityStatus.failed,
      );
      expect(failed.evidence.join(), contains('out of memory'));
      final ended = await rt.ended.timeout(const Duration(seconds: 2));
      expect(ended, isA<SessionExited>());
      expect((ended as SessionExited).code, 3);
    });

    test('dying between turns ends the session as a failure', () async {
      final machine = FakeClaudeMachine();
      final rt = runtime(machine);
      await rt.start();
      machine.current.die(1);
      final ended = await rt.ended.timeout(const Duration(seconds: 2));
      expect(ended, isA<SessionExited>());
      expect(host.statuses.last.status, AgentActivityStatus.failed);
    });

    test('stopping closes Claude\'s stdin and the session ends', () async {
      final machine = FakeClaudeMachine();
      final rt = runtime(machine);
      await rt.start();
      final end = await rt.stop();
      expect(machine.current.stdinClosed, isTrue);
      expect(end.hasEnded, isTrue);
      expect(end, isNot(isA<SessionEndedWithoutCode>()));
    });

    test(
      'a turn Claude starts by itself (a background task finishing) is '
      'written, and the session shows working while it runs, then idle',
      () async {
        final report = Completer<void>();
        final machine = FakeClaudeMachine(
          turns: [
            (c, user) async {
              c.result();
              await report.future;
              c.assistant('later', [
                {'type': 'text', 'text': 'The task finished.'},
              ]);
              await Future<void>.delayed(const Duration(milliseconds: 50));
              c.result(origin: {'kind': 'task-notification'});
            },
          ],
        );
        final rt = runtime(machine);
        await rt.start();
        await rt.send('Go');
        await rt.awaitTurn();
        expect(host.statuses.last.status, AgentActivityStatus.idle);
        report.complete();
        await until(() => rows().any((r) => r.text == 'The task finished.'));
        await until(
          () => host.statuses.last.status == AgentActivityStatus.working,
        );
        await until(
          () => host.statuses.last.status == AgentActivityStatus.idle,
        );
        expect(
          [for (final s in host.statuses) s.status],
          [
            AgentActivityStatus.idle,
            AgentActivityStatus.working,
            AgentActivityStatus.idle,
            AgentActivityStatus.working,
            AgentActivityStatus.idle,
          ],
        );
        expect(rt.inTurn, isFalse);
        await rt.stop();
      },
    );

    test('a task not said to be backgrounded holds nothing once the turn '
        'ends', () async {
      // Claude Code sends is_backgrounded only for tasks that carry it; one
      // without it, and no report after, left a finished chat "Working".
      final machine = FakeClaudeMachine(
        turns: [
          (c, user) async {
            c.toolUse('ag', 'Agent', {'description': 'Look', 'prompt': 'x'});
            c.system('task_started', {
              'task_id': 'task1',
              'tool_use_id': 'ag',
              'description': 'Look',
            });
            c.toolResult('ag', 'Found it.');
            c.result();
          },
        ],
      );
      final rt = runtime(machine);
      await rt.start();
      await rt.send('Go');
      await rt.awaitTurn();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(host.statuses.last.status, AgentActivityStatus.idle);
      expect(host.statuses.last.inFlight, isEmpty);
      await rt.stop();
    });

    test('a turn that ends with a background subagent running stays working, '
        'naming it, until the subagent reports back', () async {
      final report = Completer<void>();
      final machine = FakeClaudeMachine(
        turns: [
          (c, user) async {
            c.toolUse('ag', 'Agent', {
              'description': 'Explore the repository',
              'prompt': 'look around',
              'run_in_background': true,
            });
            c.system('task_started', {
              'task_id': 'task1',
              'tool_use_id': 'ag',
              'description': 'Explore the repository',
              'is_backgrounded': true,
            });
            c.toolResult('ag', 'Async agent launched successfully.');
            c.result();
            await report.future;
            // The subagent's own work, then its report waking Claude.
            c.toolUse(
              'sb',
              'Bash',
              {'command': 'ls'},
              parentToolUseId: 'ag',
              message: 'sub1',
            );
            c.toolResult('sb', 'a.txt', parentToolUseId: 'ag');
            c.system('task_notification', {
              'task_id': 'task1',
              'tool_use_id': 'ag',
              'status': 'completed',
              'summary': 'One file.',
            });
            c.assistant('later', [
              {'type': 'text', 'text': 'The subagent found one file.'},
            ]);
            c.result(origin: {'kind': 'task-notification'});
          },
        ],
      );
      final rt = runtime(machine);
      await rt.start();
      final sent = host.statuses.length;
      await rt.send('Go');
      await rt.awaitTurn();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final held = host.statuses.last;
      expect(held.status, AgentActivityStatus.working);
      expect(held.inFlight, ['Explore the repository']);

      report.complete();
      await until(
        () => rows().any((r) => r.text == 'The subagent found one file.'),
      );
      await until(() => host.statuses.last.status == AgentActivityStatus.idle);
      final after = [for (final s in host.statuses.skip(sent)) s.status];
      // Never idle between the prompt and the subagent's end.
      expect(after.indexOf(AgentActivityStatus.idle), after.length - 1);
      expect(host.statuses.last.inFlight, isEmpty);
      await rt.stop();
    });

    test('a prompt sent while Claude works on its own turn is answered by '
        'its own result, not the background one', () async {
      final report = Completer<void>();
      final machine = FakeClaudeMachine(
        turns: [
          (c, user) async {
            c.result();
            await report.future;
            c.assistant('later', [
              {'type': 'text', 'text': 'Background.'},
            ]);
          },
          (c, user) async {
            // Claude finishes its own turn first, then the queued prompt's.
            c.result(origin: {'kind': 'task-notification'});
            c.assistant('reply', [
              {'type': 'text', 'text': 'Answer.'},
            ]);
            c.result(stopReason: 'max_tokens');
          },
        ],
      );
      final rt = runtime(machine);
      await rt.start();
      await rt.send('Go');
      await rt.awaitTurn();
      report.complete();
      await until(() => rows().any((r) => r.text == 'Background.'));
      await rt.send('Next');
      expect(await rt.awaitTurn(), StopReason.maxTokens);
      await rt.stop();
    });
  });
}

/// [bridged] with every message it sends the runtime recorded in [wire].
AcpTransport _tapped(AcpTransport bridged, List<Json> wire) {
  return AcpTransport.streams(
    output: bridged.output.map((bytes) {
      for (final line in const LineSplitter().convert(utf8.decode(bytes))) {
        if (line.trim().isNotEmpty) wire.add(jsonDecode(line) as Json);
      }
      return bytes;
    }),
    input: bridged.input,
    exitCode: bridged.exitCode,
    errorLines: bridged.errorLines,
    kill: bridged.kill,
  );
}

/// A client choosing the first option [pick] accepts, as a person would.
final class _Choosing extends AcpClientHandler {
  _Choosing(this.pick);

  final bool Function(PermissionOption option) pick;

  @override
  Future<PermissionOutcome> requestPermission(
    String sessionId,
    ToolCallUpdate toolCall,
    List<PermissionOption> options,
  ) async => PermissionOutcome.selected(options.firstWhere(pick).optionId);

  @override
  Future<String> readTextFile(
    String sessionId,
    String path, {
    int? line,
    int? limit,
  }) => throw const AcpMethodNotSupported('fs/read_text_file');

  @override
  Future<void> writeTextFile(String sessionId, String path, String content) =>
      throw const AcpMethodNotSupported('fs/write_text_file');
}
