import 'dart:async';

import 'package:karmashala_acp/karmashala_acp.dart';
import 'package:karmashala_acp/testing.dart';
import 'package:test/test.dart';

/// A handler that records what it was asked and answers from fixed values.
class RecordingHandler extends AcpClientHandler {
  RecordingHandler({this.choose = _allowFirst, this.files = const {}});

  static Future<String> _allowFirst(List<PermissionOption> options) async =>
      options.firstWhere((o) => o.kind.allows).optionId;

  final Future<String> Function(List<PermissionOption>) choose;
  final Map<String, String> files;
  final permissionAsks = <(String sessionId, ToolCallUpdate call)>[];
  final writes = <(String path, String content)>[];

  @override
  Future<PermissionOutcome> requestPermission(
    String sessionId,
    ToolCallUpdate toolCall,
    List<PermissionOption> options,
  ) async {
    permissionAsks.add((sessionId, toolCall));
    return PermissionOutcome.selected(await choose(options));
  }

  @override
  Future<String> readTextFile(
    String sessionId,
    String path, {
    int? line,
    int? limit,
  }) async {
    final content = files[path];
    if (content == null) {
      throw const AcpRpcError(JsonRpcErrorCodes.resourceNotFound, 'no file');
    }
    return content;
  }

  @override
  Future<void> writeTextFile(
    String sessionId,
    String path,
    String content,
  ) async {
    writes.add((path, content));
  }
}

const clientInfo = ClientInfo(name: 'karmashala-test', version: '0.0.0');

void main() {
  late FakeAcpAgent agent;
  late RecordingHandler handler;
  late AcpAgentClient client;

  Future<void> connect({
    List<FakeTurn> turns = const [],
    int protocolVersion = 1,
    bool requireAuthentication = false,
    SessionModeState? modes,
    RecordingHandler? withHandler,
  }) async {
    agent = FakeAcpAgent(
      turns: turns,
      protocolVersion: protocolVersion,
      requireAuthentication: requireAuthentication,
      modes: modes,
    );
    handler = withHandler ?? RecordingHandler();
    client = AcpAgentClient(agent.clientPeer(), handler: handler);
  }

  tearDown(() async {
    await client.close();
    await agent.close();
  });

  test('initialize sends version 1, our capabilities and clientInfo, and '
      'reads the agent back', () async {
    await connect();
    final result = await client.initialize(clientInfo: clientInfo);
    expect(agent.initializeParams, {
      'protocolVersion': 1,
      'clientCapabilities': {
        'fs': {'readTextFile': true, 'writeTextFile': true},
        'terminal': false,
      },
      'clientInfo': {'name': 'karmashala-test', 'version': '0.0.0'},
    });
    expect(result.protocolVersion, 1);
    expect(result.agentCapabilities.loadSession, isTrue);
    expect(result.agentCapabilities.mcpCapabilities.http, isTrue);
    expect(result.authMethods.single.id, 'fake-login');
    expect(result.agentInfo!.name, 'fake-acp-agent');
  });

  test(
    'a protocol version other than ours throws AcpVersionMismatch',
    () async {
      await connect(protocolVersion: 2);
      await expectLater(
        client.initialize(clientInfo: clientInfo),
        throwsA(
          isA<AcpVersionMismatch>()
              .having((e) => e.ours, 'ours', 1)
              .having((e) => e.theirs, 'theirs', 2),
        ),
      );
    },
  );

  test('session/new answered -32000 throws AcpAuthenticationRequired; after '
      'authenticate it succeeds and carries modes', () async {
    await connect(
      requireAuthentication: true,
      modes: const SessionModeState(
        currentModeId: 'ask',
        availableModes: [
          SessionMode(id: 'ask', name: 'Ask'),
          SessionMode(id: 'code', name: 'Code'),
        ],
      ),
    );
    await client.initialize(clientInfo: clientInfo);
    await expectLater(
      client.newSession(cwd: '/work'),
      throwsA(isA<AcpAuthenticationRequired>()),
    );
    await client.authenticate('fake-login');
    expect(agent.authenticatedWith, 'fake-login');
    final session = await client.newSession(
      cwd: '/work',
      mcpServers: const [
        McpServerEntry.http('karmashala', url: 'http://127.0.0.1:9/mcp'),
      ],
    );
    expect(session.sessionId, 'fake-session');
    expect(session.modes!.currentModeId, 'ask');
    expect(session.modes!.availableModes.map((m) => m.id), ['ask', 'code']);
    expect(agent.newSessionParams.last['cwd'], '/work');
    expect(
      (agent.newSessionParams.last['mcpServers'] as List).single,
      containsPair('type', 'http'),
    );
  });

  test('a full turn: chunks, thought, tool call with permission answered by '
      'the handler, plan, mode, end_turn — in order', () async {
    await connect(
      turns: const [
        FakeTurn([
          FakeStep.thought('let me look'),
          FakeStep.message('Reading ', messageId: 'm1'),
          FakeStep.toolCall(
            toolCallId: 'call-1',
            title: 'Edit a.dart',
            kind: ToolKind.edit,
            rawInput: {'path': 'a.dart'},
            locations: [ToolCallLocation('a.dart', line: 1)],
            permissionOptions: fakePermissionOptions,
            completedContent: [
              ToolCallDiff(path: 'a.dart', oldText: 'x', newText: 'y'),
            ],
          ),
          FakeStep.plan([
            PlanEntry(content: 'fix', priority: PlanEntryPriority.high),
          ]),
          FakeStep.mode('code'),
          FakeStep.message('done.', messageId: 'm1'),
        ]),
      ],
    );
    await client.initialize(clientInfo: clientInfo);
    final session = await client.newSession(cwd: '/work');
    final updates = <SessionUpdate>[];
    final sub = client.updates.listen((e) {
      expect(e.sessionId, session.sessionId);
      updates.add(e.update);
    });
    final reason = await client.prompt(
      session.sessionId,
      textPrompt('fix a.dart'),
    );
    await sub.cancel();

    expect(reason, StopReason.endTurn);
    expect(agent.prompts.single.single, isA<TextContent>());
    expect(updates.map((u) => u.sessionUpdate), [
      'agent_thought_chunk',
      'agent_message_chunk',
      'tool_call',
      'tool_call_update',
      'tool_call_update',
      'plan',
      'current_mode_update',
      'agent_message_chunk',
    ]);
    final opened = updates[2] as ToolCallUpdate;
    expect(opened.isNew, isTrue);
    expect(opened.title, 'Edit a.dart');
    expect(opened.kind, ToolKind.edit);
    expect(opened.status, ToolCallStatus.pending);
    expect(opened.rawInput, {'path': 'a.dart'});
    final completed = updates[4] as ToolCallUpdate;
    expect(completed.status, ToolCallStatus.completed);
    expect(completed.content!.single, isA<ToolCallDiff>());
    expect(
      (updates[5] as PlanUpdate).entries.single.priority,
      PlanEntryPriority.high,
    );
    expect((updates[6] as CurrentModeUpdate).currentModeId, 'code');
    expect((updates[1] as AgentMessageChunk).messageId, 'm1');

    expect(handler.permissionAsks.single.$1, session.sessionId);
    expect(handler.permissionAsks.single.$2.toolCallId, 'call-1');
    expect(agent.permissionOutcomes.single, const PermissionSelected('allow'));
  });

  test('a rejected permission fails the tool call; the turn goes on', () async {
    await connect(
      turns: const [
        FakeTurn([
          FakeStep.toolCall(
            toolCallId: 'c',
            title: 'rm -rf',
            kind: ToolKind.execute,
            permissionOptions: fakePermissionOptions,
          ),
          FakeStep.message('skipped it'),
        ]),
      ],
      withHandler: RecordingHandler(choose: (_) async => 'reject'),
    );
    await client.initialize(clientInfo: clientInfo);
    final session = await client.newSession(cwd: '/work');
    final statuses = client.updates
        .map((e) => e.update)
        .where((u) => u is ToolCallUpdate)
        .cast<ToolCallUpdate>()
        .map((u) => u.status)
        .toList();
    expect(
      await client.prompt(session.sessionId, textPrompt('go')),
      StopReason.endTurn,
    );
    await client.close();
    expect(await statuses, [ToolCallStatus.pending, ToolCallStatus.failed]);
  });

  test('cancel mid-turn: the prompt answers cancelled, and a permission '
      'request still open is answered cancelled by the client', () async {
    final asked = Completer<void>();
    final neverAnswers = Completer<String>();
    await connect(
      turns: const [
        FakeTurn([
          FakeStep.message('working'),
          FakeStep.toolCall(
            toolCallId: 'c',
            title: 'slow',
            permissionOptions: fakePermissionOptions,
          ),
          FakeStep.message('never sent'),
        ]),
        FakeTurn([FakeStep.message('first'), FakeStep.waitForCancel()]),
      ],
      withHandler: RecordingHandler(
        choose: (_) {
          asked.complete();
          return neverAnswers.future;
        },
      ),
    );
    await client.initialize(clientInfo: clientInfo);
    final session = await client.newSession(cwd: '/work');
    final texts = <String>[];
    client.updates.listen((e) {
      if (e.update case AgentMessageChunk(content: TextContent(:final text))) {
        texts.add(text);
      }
    });

    final turn1 = client.prompt(session.sessionId, textPrompt('one'));
    await asked.future;
    client.cancel(session.sessionId);
    expect(await turn1, StopReason.cancelled);
    expect(agent.permissionOutcomes.single, const PermissionCancelled());
    expect(agent.cancels, 1);

    final turn2 = client.prompt(session.sessionId, textPrompt('two'));
    await Future<void>.delayed(Duration.zero);
    while (!texts.contains('first')) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    client.cancel(session.sessionId);
    expect(await turn2, StopReason.cancelled);
    expect(texts, ['working', 'first']);
    expect(agent.isInTurn, isFalse);
  });

  test('fs/read_text_file and fs/write_text_file reach the handler; a '
      'handler AcpRpcError is passed through with its code', () async {
    await connect(
      turns: const [
        FakeTurn([
          FakeStep.readFile('/work/a.txt', line: 1, limit: 10),
          FakeStep.readFile('/work/missing.txt'),
          FakeStep.writeFile('/work/b.txt', 'bee'),
        ]),
      ],
      withHandler: RecordingHandler(files: {'/work/a.txt': 'alpha'}),
    );
    await client.initialize(clientInfo: clientInfo);
    final session = await client.newSession(cwd: '/work');
    final reason = await client.prompt(session.sessionId, textPrompt('io'));
    expect(reason, StopReason.endTurn);
    expect(agent.readFileResults, ['alpha']);
    expect(
      agent.fsErrors.single,
      isA<AcpRpcError>().having((e) => e.code, 'code', -32002),
    );
    expect(handler.writes, [('/work/b.txt', 'bee')]);
  });

  test('a terminal method is answered -32601; an unknown method too', () async {
    await connect();
    await client.initialize(clientInfo: clientInfo);
    await expectLater(
      agent.peer.call('terminal/create', {'sessionId': 's', 'command': 'ls'}),
      throwsA(isA<AcpRpcError>().having((e) => e.code, 'code', -32601)),
    );
    await expectLater(
      agent.peer.call('session/surprise', null),
      throwsA(
        isA<AcpRpcError>()
            .having((e) => e.code, 'code', -32601)
            .having((e) => e.message, 'message', contains('session/surprise')),
      ),
    );
  });

  test('setMode and setConfigOption send their params; loadSession replays '
      'updates before answering', () async {
    agent = FakeAcpAgent(
      loadReplay: const [
        UserMessageChunk(TextContent('earlier')),
        AgentMessageChunk(TextContent('reply')),
      ],
      configOptions: const [
        ConfigOption(id: 'model', name: 'Model', type: 'select'),
      ],
    );
    handler = RecordingHandler();
    client = AcpAgentClient(agent.clientPeer(), handler: handler);
    await client.initialize(clientInfo: clientInfo);
    final replayed = client.updates.take(2).toList();
    final loaded = await client.loadSession(sessionId: 'old', cwd: '/work');
    expect(loaded.configOptions!.single.id, 'model');
    expect((await replayed).map((e) => e.update.sessionUpdate), [
      'user_message_chunk',
      'agent_message_chunk',
    ]);
    expect(agent.loadSessionParams.single['sessionId'], 'old');

    await client.setMode('old', 'code');
    expect(agent.modeChanges, ['code']);
    final options = await client.setConfigOption(
      'old',
      'model',
      valueId: 'big',
    );
    expect(options.single.id, 'model');
    // The fake moves the value it was handed and answers the list as it stands.
    expect(options.single.currentValue, 'big');
    expect(agent.configOptions!.single.currentValue, 'big');
    expect(agent.configChanges.single, {
      'sessionId': 'old',
      'configId': 'model',
      'value': 'big',
    });
    await client.setConfigOption('old', 'think', flag: true);
    expect(agent.configChanges.last, {
      'sessionId': 'old',
      'configId': 'think',
      'type': 'boolean',
      'value': true,
    });
    expect(() => client.setConfigOption('old', 'x'), throwsArgumentError);
  });

  test('an unknown update variant from the agent still arrives, as '
      'UnknownUpdate', () async {
    await connect(
      turns: const [
        FakeTurn([
          FakeStep.rawUpdate({'sessionUpdate': 'mood_update', 'mood': 'calm'}),
        ]),
      ],
    );
    await client.initialize(clientInfo: clientInfo);
    final session = await client.newSession(cwd: '/work');
    final first = client.updates.first;
    await client.prompt(session.sessionId, textPrompt('?'));
    final update = (await first).update;
    expect(update, isA<UnknownUpdate>());
    expect((update as UnknownUpdate).raw['mood'], 'calm');
  });
}
