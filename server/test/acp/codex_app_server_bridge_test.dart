import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart'
    show AcpLaunchSpec, AcpNativeBridge, AgentActivityStatus, PermissionRisk;
import 'package:agent_cli/process.dart' show EnvironmentKind;
import 'package:karmashala_acp/karmashala_acp.dart';
import 'package:karmashala_host/src/acp/acp_login_link.dart';
import 'package:karmashala_host/src/acp/acp_native_bridge.dart';
import 'package:karmashala_host/src/acp/acp_session_runtime.dart';
import 'package:karmashala_host/src/acp/acp_transport.dart';
import 'package:karmashala_host/src/acp/acp_usage_limit.dart'
    show kProtocolUsageLimitReason;
import 'package:karmashala_host/src/acp/acp_version_probe.dart';
import 'package:karmashala_host/src/acp/codex/codex_app_server_bridge.dart';
import 'package:karmashala_host_protocol/protocol.dart' show SessionExited;
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'acp_fixture.dart';
import 'fake_codex_app_server.dart';

const _spec = AcpLaunchSpec(
  arguments: ['app-server'],
  nativeBridge: AcpNativeBridge.codexAppServer,
  modeNames: {
    PermissionRisk.readOnly: ['read-only'],
    PermissionRisk.ask: ['workspace-write'],
    PermissionRisk.acceptEdits: ['workspace-write'],
    PermissionRisk.autoRun: ['agent'],
    PermissionRisk.bypass: ['agent-full-access'],
  },
);

/// Codex's app-server, translated to ACP in-process, under the real session
/// runtime: a fake app-server peer stands in for `codex app-server`.
void main() {
  late AppDatabase database;
  late Directory temp;
  late RecordingHost host;

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    temp = Directory.systemTemp.createTempSync('codex_bridge_test');
    host = RecordingHost();
  });

  tearDown(() {
    database.close();
    temp.deleteSync(recursive: true);
  });

  List<SessionMessage> rows() => SessionMessageDao(database).listAfter('s1');

  List<AgentActivityStatus> statuses() => [
    for (final report in host.statuses) report.status,
  ];

  AcpSessionRuntime runtimeOver(
    FakeCodexAppServer codex, {
    PermissionRisk? risk,
    String? resumeSessionId,
    String? mcpUrl,
  }) {
    var ids = 0;
    return AcpSessionRuntime(
      id: 'karmashala_s1',
      sessionId: 's1',
      agentId: 'codex-acp',
      agentName: 'Codex',
      spec: _spec,
      workingDirectory: temp.path,
      spawn: () async => bridgedAcpTransport(_spec, codex.transport),
      messages: SessionMessageDao(database),
      usage: SessionUsageDao(database),
      host: host,
      mcpUrl: mcpUrl,
      risk: risk,
      resumeSessionId: resumeSessionId,
      newId: () => 'm${++ids}',
      coalesce: const Duration(milliseconds: 20),
      stopPatience: const Duration(milliseconds: 200),
    );
  }

  test('the build carries the bridge for codexAppServer', () {
    expect(kAcpNativeBridges[AcpNativeBridge.codexAppServer], isNotNull);
  });

  test('initialize: Codex\'s version, load support, and its login as the '
      'auth method', () async {
    final codex = FakeCodexAppServer();
    final version = await readAcpAgentVersion(
      () async => codexAppServerBridge(codex.transport),
      clientName: 'Karmashala',
      clientVersion: '9.9.9',
    );
    expect(version, '0.160.0');
    expect(codex.callsTo('initialize').single['clientInfo'], {
      'name': 'Karmashala',
      'title': null,
      'version': '9.9.9',
    });
    expect(codex.notifications, contains('initialized'));

    final again = FakeCodexAppServer();
    final init = await talkToAcpAgent(
      () async => codexAppServerBridge(again.transport),
      (_, init) async => init,
    );
    expect(init.protocolVersion, 1);
    expect(init.agentInfo?.name, 'codex');
    expect(init.agentCapabilities.loadSession, isTrue);
    expect(init.agentCapabilities.promptCapabilities.image, isTrue);
    expect(init.agentCapabilities.mcpCapabilities.http, isTrue);
    expect(init.agentCapabilities.supportsLogout, isTrue);
    expect(init.authMethods.map((m) => m.id), ['chatgpt']);
    expect(init.authMethods.single.isTerminal, isFalse);
    expect(init.authMethods.single.description, contains('plus'));
    // The account's email is not repeated anywhere ACP carries.
    expect(jsonEncode(init.toJson()), isNot(contains('someone@example.com')));
  });

  test('authenticate runs Codex\'s ChatGPT login, says its link on stderr, '
      'and answers once the login completed', () async {
    final codex = FakeCodexAppServer(account: null);
    final lines = <String>[];
    await talkToAcpAgent(() async => codexAppServerBridge(codex.transport), (
      peer,
      init,
    ) async {
      expect(init.authMethods.single.description, contains('browser'));
      // Not logged in: a session is refused as ACP's auth_required.
      await expectLater(
        peer.call(AcpMethods.sessionNew, {
          'cwd': temp.path,
          'mcpServers': <Object?>[],
        }),
        throwsA(isA<AcpAuthenticationRequired>()),
      );
      await peer.call(AcpMethods.authenticate, {'methodId': 'chatgpt'});
      final created = await peer.call(AcpMethods.sessionNew, {
        'cwd': temp.path,
        'mcpServers': <Object?>[],
      });
      expect((created! as Map)['sessionId'], 'thr-new');
    }, onErrorLine: lines.add);
    expect(codex.callsTo('account/login/start').single, {'type': 'chatgpt'});
    expect(
      lines.join('\n'),
      contains('https://auth.example.com/oauth?state=1'),
    );
  });

  test(
    'session/new starts a thread with Karmashala\'s MCP server, offers '
    'Codex\'s modes, models and efforts, and a mode is sent with the turn',
    () async {
      final codex = FakeCodexAppServer(
        onTurn: (turn) async => turn.end('completed'),
      );
      final runtime = runtimeOver(
        codex,
        risk: PermissionRisk.readOnly,
        mcpUrl: 'http://127.0.0.1:1234/mcp/tok',
      );
      final outcome = await runtime.start();
      expect(outcome.agentSessionId, 'thr-new');
      expect(outcome.resumed, isFalse);
      final started = codex.callsTo('thread/start').single;
      expect(started['cwd'], temp.path);
      expect(started['config'], {
        'mcp_servers.karmashala.url': 'http://127.0.0.1:1234/mcp/tok',
      });

      final modes = runtime.modes!;
      expect(modes.availableModes.map((m) => m.id), [
        'read-only',
        'workspace-write',
        'agent',
        'agent-full-access',
      ]);
      // The thread opened in workspace-write; the session's rung moved it.
      expect(modes.currentModeId, 'read-only');

      final options = runtime.configOptions!.options;
      final model = options.firstWhere((o) => o.id == 'model');
      expect(model.currentValue, 'gpt-fast');
      expect(model.choices.map((c) => c.value), ['gpt-fast', 'gpt-deep']);
      final effort = options.firstWhere((o) => o.id == 'reasoning_effort');
      expect(effort.currentValue, 'medium');
      expect(effort.choices.map((c) => c.value), ['low', 'medium']);

      await runtime.send('Look around');
      expect(await runtime.awaitTurn(), StopReason.endTurn);
      final turn = codex.callsTo('turn/start').single;
      expect(turn['threadId'], 'thr-new');
      expect(turn['input'], [
        {'type': 'text', 'text': 'Look around', 'text_elements': <Object?>[]},
      ]);
      expect(turn['approvalPolicy'], 'on-request');
      expect(turn['sandboxPolicy'], {
        'type': 'readOnly',
        'networkAccess': false,
      });
      // Nothing the person did not choose is overridden.
      expect(turn.containsKey('model'), isFalse);
      expect(turn.containsKey('effort'), isFalse);
      await runtime.stop();
    },
  );

  test('a model chosen moves the efforts offered, and both ride the next '
      'turn; a mode keeps the thread\'s own sandbox of its kind', () async {
    final codex = FakeCodexAppServer(
      onTurn: (turn) async => turn.end('completed'),
    );
    final runtime = runtimeOver(codex);
    await runtime.start();
    await runtime.setConfigOption('model', 'gpt-deep');
    final effort = runtime.configOptions!.options.firstWhere(
      (o) => o.id == 'reasoning_effort',
    );
    expect(effort.choices.map((c) => c.value), ['high', 'xhigh']);
    expect(effort.currentValue, 'high');
    await runtime.setConfigOption('reasoning_effort', 'xhigh');
    await runtime.setMode('agent');
    await runtime.send('Go deep');
    await runtime.awaitTurn();
    final turn = codex.callsTo('turn/start').single;
    expect(turn['model'], 'gpt-deep');
    expect(turn['effort'], 'xhigh');
    expect(turn['approvalPolicy'], 'never');
    expect((turn['sandboxPolicy']! as Map)['writableRoots'], ['/extra']);
    await runtime.stop();
  });

  test('a turn streams text and reasoning, tool calls with kind and input, '
      'command output, a file change as a diff, the plan, and usage', () async {
    final codex = FakeCodexAppServer(
      onTurn: (turn) async {
        turn.notify('item/reasoning/summaryTextDelta', {
          'itemId': 'r1',
          'delta': 'Thinking it over.',
          'summaryIndex': 0,
        });
        turn.notify('turn/plan/updated', {
          'explanation': 'Two steps',
          'plan': [
            {'step': 'Read the file', 'status': 'inProgress'},
            {'step': 'Fix it', 'status': 'pending'},
          ],
        });
        final read = {
          'type': 'commandExecution',
          'id': 'exec-1',
          'command': 'bash -lc "cat a.txt"',
          'cwd': temp.path,
          'status': 'inProgress',
          'commandActions': [
            {
              'type': 'read',
              'command': 'cat a.txt',
              'name': 'a.txt',
              'path': 'a.txt',
            },
          ],
          'aggregatedOutput': null,
          'exitCode': null,
        };
        turn.started(read);
        turn.delta('item/commandExecution/outputDelta', 'exec-1', 'one\n');
        turn.delta('item/commandExecution/outputDelta', 'exec-1', 'two\n');
        await settle(const Duration(milliseconds: 200));
        turn.completed({
          ...read,
          'status': 'completed',
          'aggregatedOutput': 'one\ntwo\n',
          'exitCode': 0,
          'durationMs': 12,
        });
        final edit = {
          'type': 'fileChange',
          'id': 'patch-1',
          'status': 'inProgress',
          'changes': [
            {
              'path': 'a.txt',
              'kind': {'type': 'update', 'move_path': null},
              'diff': '@@ -1,2 +1,2 @@\n one\n-two\n+three\n',
            },
            {
              'path': 'b.txt',
              'kind': {'type': 'add'},
              'diff': 'new file\n',
            },
          ],
        };
        turn.started(edit);
        turn.completed({...edit, 'status': 'completed'});
        turn.started({
          'type': 'mcpToolCall',
          'id': 'mcp-1',
          'server': 'karmashala',
          'tool': 'list_sessions',
          'status': 'inProgress',
          'arguments': {'limit': 1},
          'readOnlyHint': true,
        });
        turn.completed({
          'type': 'mcpToolCall',
          'id': 'mcp-1',
          'server': 'karmashala',
          'tool': 'list_sessions',
          'status': 'completed',
          'arguments': {'limit': 1},
          'readOnlyHint': true,
          'result': {
            'content': [
              {'type': 'text', 'text': 'no sessions'},
            ],
            'structuredContent': null,
          },
        });
        turn.delta('item/agentMessage/delta', 'msg-1', 'Changed ');
        turn.delta('item/agentMessage/delta', 'msg-1', 'two to three.');
        turn.notify('thread/tokenUsage/updated', {
          'tokenUsage': {
            'total': {'totalTokens': 5000},
            'last': {'totalTokens': 1800},
            'modelContextWindow': 200000,
          },
        });
        turn.server.notify('account/rateLimits/updated', {
          'rateLimits': {
            'primary': {
              'usedPercent': 12,
              'windowDurationMins': 300,
              'resetsAt': 1791128347,
            },
          },
        });
        turn.notify('turn/diff/updated', {'diff': 'diff --git a/a.txt'});
        turn.end('completed');
      },
    );
    final runtime = runtimeOver(codex, risk: PermissionRisk.acceptEdits);
    await runtime.start();
    await runtime.send('Fix a.txt');
    expect(await runtime.awaitTurn(), StopReason.endTurn);

    final written = rows();
    final agent = written.where((r) => r.role == SessionMessageRole.agent);
    expect(agent.where((r) => r.planJson != null), hasLength(1));
    final plan = jsonDecode(
      agent.firstWhere((r) => r.planJson != null).planJson!,
    );
    expect(plan['entries'], [
      {
        'content': 'Read the file',
        'priority': 'medium',
        'status': 'in_progress',
      },
      {'content': 'Fix it', 'priority': 'medium', 'status': 'pending'},
    ]);
    expect(
      agent.map((r) => r.thinking).whereType<String>().join(),
      'Thinking it over.',
    );
    expect(agent.last.text, 'Changed two to three.');
    expect(agent.last.messageId, 'msg-1');

    final tools = {
      for (final r in written.where((r) => r.role == SessionMessageRole.tool))
        (jsonDecode(r.toolJson!) as Map)['toolCallId']:
            jsonDecode(r.toolJson!) as Map,
    };
    final read = tools['exec-1']!;
    expect(read['kind'], 'read');
    expect(read['title'], 'cat a.txt');
    expect(read['status'], 'completed');
    expect((read['rawInput'] as Map)['command'], 'bash -lc "cat a.txt"');
    expect(read['content'], [
      {
        'type': 'content',
        'content': {'type': 'text', 'text': 'one\ntwo\n'},
      },
    ]);
    expect(read['rawOutput'], {'exitCode': 0});
    expect((read['locations'] as List).single['path'], endsWith('a.txt'));

    final edit = tools['patch-1']!;
    expect(edit['kind'], 'edit');
    expect(edit['status'], 'completed');
    final diffs = (edit['content'] as List).cast<Map>();
    expect(diffs.map((d) => d['type']), ['diff', 'diff']);
    expect(diffs[0]['path'], endsWith('a.txt'));
    expect(diffs[0]['oldText'], 'one\ntwo');
    expect(diffs[0]['newText'], 'one\nthree');
    expect(diffs[1]['oldText'], isNull);
    expect(diffs[1]['newText'], 'new file\n');
    // The edit's files reached the checkpoint.
    expect(host.touched, containsAll([diffs[0]['path'], diffs[1]['path']]));

    final mcp = tools['mcp-1']!;
    expect(mcp['title'], 'karmashala: list_sessions');
    expect(mcp['kind'], 'read');
    expect(mcp['rawInput'], {'limit': 1});
    expect(((mcp['content'] as List).single as Map)['content'], {
      'type': 'text',
      'text': 'no sessions',
    });

    expect(host.usage.last.contextUsed, 1800);
    expect(host.usage.last.contextSize, 200000);
    await runtime.stop();
  });

  test('a command approval asks the runtime, and an allow reaches Codex as '
      'accept', () async {
    late Future<Object?> answered;
    final codex = FakeCodexAppServer(
      onTurn: (turn) async {
        answered = turn.ask('item/commandExecution/requestApproval', {
          'itemId': 'exec-9',
          'kind': 'command',
          'reason': 'needs the network',
          'command': 'curl example.com',
          'cwd': temp.path,
          'commandActions': [
            {'type': 'unknown', 'command': 'curl example.com'},
          ],
        });
        await answered;
        turn.end('completed');
      },
    );
    final runtime = runtimeOver(codex, risk: PermissionRisk.ask);
    await runtime.start();
    await runtime.send('Fetch it');
    await pump(40);
    expect(runtime.hasOpenPermission, isTrue);
    expect(runtime.pendingToolCallId, 'exec-9');
    final waiting = host.statuses.last;
    expect(waiting.status, AgentActivityStatus.awaitingApproval);
    expect(waiting.toolAsk?.toolName, 'curl example.com');
    final answer = await runtime.answerPermission(approve: true);
    expect(answer.granted, isTrue);
    expect(await answered, {'decision': 'accept'});
    expect(await runtime.awaitTurn(), StopReason.endTurn);
    await runtime.stop();
  });

  test('a refused file change reaches Codex as decline, with its diff shown '
      'in the request', () async {
    late Future<Object?> answered;
    final codex = FakeCodexAppServer(
      onTurn: (turn) async {
        final edit = {
          'type': 'fileChange',
          'id': 'patch-2',
          'status': 'inProgress',
          'changes': [
            {
              'path': 'c.txt',
              'kind': {'type': 'update', 'move_path': null},
              'diff': '@@ -1 +1 @@\n-old\n+new\n',
            },
          ],
        };
        turn.started(edit);
        answered = turn.ask('item/fileChange/requestApproval', {
          'itemId': 'patch-2',
          'reason': 'outside the workspace',
        });
        await answered;
        turn.completed({...edit, 'status': 'declined'});
        turn.end('completed');
      },
    );
    final runtime = runtimeOver(codex, risk: PermissionRisk.ask);
    await runtime.start();
    await runtime.send('Edit c');
    await pump(40);
    expect(runtime.hasOpenPermission, isTrue);
    expect(host.statuses.last.toolAsk?.toolName, 'Edit c.txt');
    final answer = await runtime.answerPermission(approve: false);
    expect(answer.granted, isFalse);
    expect(await answered, {'decision': 'decline'});
    await runtime.awaitTurn();
    final tool = jsonDecode(
      rows().firstWhere((r) => r.role == SessionMessageRole.tool).toolJson!,
    );
    expect(tool['status'], 'failed');
    await runtime.stop();
  });

  test('a cancel mid-turn interrupts Codex\'s turn, and the turn ends '
      'cancelled', () async {
    final codex = FakeCodexAppServer(
      onTurn: (turn) async {
        turn.delta('item/agentMessage/delta', 'msg-1', 'Working');
        await turn.interrupted.future;
        turn.end('interrupted');
      },
    );
    final runtime = runtimeOver(codex);
    await runtime.start();
    await runtime.send('Take your time');
    await pump(40);
    runtime.cancel();
    expect(await runtime.awaitTurn(), StopReason.cancelled);
    expect(codex.callsTo('turn/interrupt').single, {
      'threadId': 'thr-new',
      'turnId': 'turn-1',
    });
    expect(statuses().last, AgentActivityStatus.idle);
    await runtime.stop();
  });

  test('Codex dying mid-turn fails the turn and ends the session with its '
      'exit code', () async {
    final codex = FakeCodexAppServer(
      onTurn: (turn) async {
        turn.delta('item/agentMessage/delta', 'msg-1', 'Starting');
      },
    );
    final runtime = runtimeOver(codex);
    await runtime.start();
    await runtime.send('Go');
    await pump(40);
    await codex.die(3);
    await runtime.awaitTurn();
    expect(host.statuses.last.status, AgentActivityStatus.failed);
    final end = await runtime.ended;
    expect(end, isA<SessionExited>().having((e) => e.exitCode, 'code', 3));
  });

  test(
    'a usage limit fails the turn as a usage limit, with when it resets',
    () async {
      final codex = FakeCodexAppServer(
        onTurn: (turn) async {
          turn.server.notify('account/rateLimits/updated', {
            'rateLimits': {
              'primary': {
                'usedPercent': 100,
                'windowDurationMins': 300,
                'resetsAt': 1791128347,
              },
            },
          });
          turn.end(
            'failed',
            error: {
              'message': "You've hit your usage limit.",
              'codexErrorInfo': 'usageLimitExceeded',
              'additionalDetails': null,
            },
          );
        },
      );
      final runtime = runtimeOver(codex);
      await runtime.start();
      await runtime.send('More');
      await runtime.awaitTurn();
      final last = host.statuses.last;
      expect(last.status, AgentActivityStatus.failed);
      expect(last.failureReason, kProtocolUsageLimitReason);
      expect(last.evidence.join(' '), contains('1791128347'));
      await runtime.stop();
    },
  );

  test('a context window overflow ends the turn as max_tokens', () async {
    final codex = FakeCodexAppServer(
      onTurn: (turn) async => turn.end(
        'failed',
        error: {
          'message': 'The context window is full.',
          'codexErrorInfo': 'contextWindowExceeded',
        },
      ),
    );
    final runtime = runtimeOver(codex);
    await runtime.start();
    await runtime.send('Again');
    expect(await runtime.awaitTurn(), StopReason.maxTokens);
    await runtime.stop();
  });

  test('session/load resumes the Codex thread, replaying it without writing '
      'rows twice', () async {
    final codex = FakeCodexAppServer(threads: {});
    final old = codex.thread(
      'thr-old',
      name: 'Earlier work',
      turns: [
        {
          'id': 't0',
          'status': 'completed',
          'items': [
            {
              'type': 'userMessage',
              'id': 'u0',
              'content': [
                {'type': 'text', 'text': 'Hi', 'text_elements': <Object?>[]},
              ],
            },
            {'type': 'agentMessage', 'id': 'a0', 'text': 'Hello.'},
          ],
        },
      ],
    );
    final resumable = FakeCodexAppServer(threads: {'thr-old': old});
    final runtime = runtimeOver(resumable, resumeSessionId: 'thr-old');
    final outcome = await runtime.start();
    expect(outcome.resumed, isTrue);
    expect(outcome.agentSessionId, 'thr-old');
    expect(resumable.callsTo('thread/resume').single['threadId'], 'thr-old');
    expect(resumable.callsTo('thread/start'), isEmpty);
    expect(rows(), isEmpty);
    await runtime.stop();
    await codex.die(0);
  });

  test('a session the old adapter started, which Codex does not hold, goes '
      'on as a fresh thread and says so', () async {
    final codex = FakeCodexAppServer();
    final runtime = runtimeOver(codex, resumeSessionId: 'adapter-session');
    final outcome = await runtime.start();
    expect(outcome.resumed, isFalse);
    expect(outcome.agentSessionId, 'thr-new');
    expect(outcome.notices.join(' '), contains('no longer holds'));
    await runtime.stop();
  });

  test(
    'a stop closes Codex\'s stdin, and Codex ending ends the session',
    () async {
      final codex = FakeCodexAppServer();
      final runtime = runtimeOver(codex);
      await runtime.start();
      final stopped = runtime.stop();
      await pump();
      await codex.die(0);
      await stopped;
      expect(runtime.lifecycle.hasEnded, isTrue);
    },
  );

  test('a login needed at the start opens its link on this machine and says '
      'so in the chat, then the session starts', () async {
    final codex = FakeCodexAppServer(account: null);
    final opened = <Uri>[];
    var ids = 0;
    final runtime = AcpSessionRuntime(
      id: 'karmashala_s1',
      sessionId: 's1',
      agentId: 'codex-acp',
      agentName: 'Codex',
      spec: _spec,
      workingDirectory: temp.path,
      spawn: () async => openingLoginLinks(
        bridgedAcpTransport(_spec, codex.transport),
        open: opened.add,
        agentName: 'Codex',
      ),
      messages: SessionMessageDao(database),
      host: host,
      newId: () => 'm${++ids}',
      coalesce: const Duration(milliseconds: 20),
      stopPatience: const Duration(milliseconds: 200),
    );
    final outcome = await runtime.start();
    expect(outcome.agentSessionId, 'thr-new');
    expect(opened, [Uri.parse('https://auth.example.com/oauth?state=1')]);
    await settle(const Duration(milliseconds: 60));
    final said = rows().map((r) => r.text).join('\n');
    expect(said, contains('browser login was opened'));
    expect(said, contains('https://auth.example.com/oauth?state=1'));
    await runtime.stop();
  });

  test('the server opens a login link for an agent in WSL or behind a '
      'bridge; elsewhere the agent opens its own', () {
    const plain = AcpLaunchSpec();
    expect(serverOpensLoginLinks(EnvironmentKind.wsl, plain), isTrue);
    expect(serverOpensLoginLinks(EnvironmentKind.windowsNative, _spec), isTrue);
    expect(
      serverOpensLoginLinks(EnvironmentKind.windowsNative, plain),
      isFalse,
    );
    expect(serverOpensLoginLinks(null, plain), isFalse);
  });

  test('a line said into the chat waits for the end of a line the agent is '
      'still writing', () async {
    final out = StreamController<List<int>>();
    final errors = StreamController<String>();
    final wrapped = openingLoginLinks(
      AcpTransport.streams(
        output: out.stream,
        input: StreamController<List<int>>(),
        exitCode: Completer<int>().future,
        errorLines: errors.stream,
      ),
      open: (_) {},
      agentName: 'Agent',
    );
    final text = StringBuffer();
    wrapped.output.listen((bytes) => text.write(utf8.decode(bytes)));
    wrapped.errorLines.listen((_) {});
    out.add(utf8.encode('{"a":'));
    await pump();
    errors.add('Open https://login.example.com/x to log in');
    await pump();
    out.add(utf8.encode('1}\n'));
    await pump();
    final lines = const LineSplitter().convert(text.toString());
    expect(lines.first, '{"a":1}');
    expect(lines[1], contains('login.example.com'));
    expect(jsonDecode(lines[1]), isA<Map<String, Object?>>());
  });

  JsonMap question(String id, String text, [List<String>? choices]) => {
    'id': id,
    'header': 'Choose',
    'question': text,
    'isOther': false,
    'isSecret': false,
    'options': choices == null
        ? null
        : [
            for (final c in choices) {'label': c, 'description': 'about $c'},
          ],
  };

  test('a question with choices asks the person, even under autoRun, and '
      'the choice reaches Codex', () async {
    late Future<Object?> answered;
    final codex = FakeCodexAppServer(
      onTurn: (turn) async {
        answered = turn.ask('item/tool/requestUserInput', {
          'itemId': 'ask-1',
          'questions': [
            question('q1', 'Which database?', ['sqlite', 'postgres']),
          ],
          'isBlocking': true,
          'autoResolutionMs': null,
        });
        await answered;
        turn.end('completed');
      },
    );
    final runtime = runtimeOver(codex, risk: PermissionRisk.autoRun);
    await runtime.start();
    await runtime.send('Set it up');
    await pump(40);
    // Answering for the person would pick a choice they never saw.
    expect(runtime.hasOpenPermission, isTrue);
    expect(host.statuses.last.toolAsk?.toolName, 'Which database?');
    await runtime.answerPermission(approve: true);
    expect(await answered, {
      'answers': {
        'q1': {
          'answers': ['sqlite'],
        },
      },
    });
    await runtime.awaitTurn();
    await runtime.stop();
  });

  test('every choice is an option a client can pick, and the one picked is '
      'sent back', () async {
    late Future<Object?> answered;
    final codex = FakeCodexAppServer(
      onTurn: (turn) async {
        answered = turn.ask('item/tool/requestUserInput', {
          'itemId': 'ask-2',
          'questions': [
            question('q1', 'Which database?', ['sqlite', 'postgres']),
          ],
          'isBlocking': true,
        });
        await answered;
        turn.end('completed');
      },
    );
    final offered = <List<JsonMap>>[];
    await talkToAcpAgent(() async => codexAppServerBridge(codex.transport), (
      peer,
      init,
    ) async {
      peer.requests.listen((request) {
        final options = request.paramsMap['options']! as List;
        offered.add([for (final o in options) (o as Map).cast()]);
        request.respond({
          'outcome': {
            'outcome': 'selected',
            'optionId': options[1]['optionId'],
          },
        });
      });
      final created = await peer.call(AcpMethods.sessionNew, {
        'cwd': temp.path,
        'mcpServers': <Object?>[],
      });
      await peer.call(AcpMethods.sessionPrompt, {
        'sessionId': (created! as Map)['sessionId'],
        'prompt': [
          {'type': 'text', 'text': 'Set it up'},
        ],
      });
    });
    expect(offered.single.map((o) => (o['name'], o['kind'])), [
      ('sqlite', 'allow_always'),
      ('postgres', 'allow_always'),
      ('Skip the question', 'reject_once'),
    ]);
    expect(await answered, {
      'answers': {
        'q1': {
          'answers': ['postgres'],
        },
      },
    });
  });

  test('a free-text question is declined, and the chat says so', () async {
    late Future<Object?> answered;
    final codex = FakeCodexAppServer(
      onTurn: (turn) async {
        answered = turn.ask('item/tool/requestUserInput', {
          'itemId': 'ask-3',
          'questions': [question('q1', 'What should the table be called?')],
          'isBlocking': true,
        });
        await answered;
        turn.end('completed');
      },
    );
    final runtime = runtimeOver(codex, risk: PermissionRisk.ask);
    await runtime.start();
    await runtime.send('Make a table');
    await runtime.awaitTurn();
    expect(await answered, {'answers': <String, Object?>{}});
    expect(runtime.hasOpenPermission, isFalse);
    final said = rows()
        .where((r) => r.role == SessionMessageRole.agent)
        .map((r) => r.text)
        .join('\n');
    expect(said, contains('What should the table be called?'));
    expect(said, contains('declined'));
    await runtime.stop();
  });

  test(
    'an MCP server\'s request for input is declined, and the chat says so',
    () async {
      late Future<Object?> answered;
      final codex = FakeCodexAppServer(
        onTurn: (turn) async {
          answered = turn.ask('mcpServer/elicitation/request', {
            'serverName': 'tracker',
            'mode': 'form',
            'message': 'Pick a project',
            'requestedSchema': <String, Object?>{},
          });
          await answered;
          turn.end('completed');
        },
      );
      final runtime = runtimeOver(codex);
      await runtime.start();
      await runtime.send('Ask me');
      await runtime.awaitTurn();
      expect((await answered)! as Map, containsPair('action', 'decline'));
      final said = rows()
          .where((r) => r.role == SessionMessageRole.agent)
          .map((r) => r.text)
          .join('\n');
      expect(said, contains('tracker'));
      expect(said, contains('Pick a project'));
      expect(said, contains('declined'));
      await runtime.stop();
    },
  );
}
