import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart'
    show
        AcpLaunchSpec,
        AgentActivityStatus,
        AgentStatusSource,
        AgentWaitKind,
        PermissionRisk;
import 'package:karmashala_acp/karmashala_acp.dart'
    show
        AcpRpcError,
        AgentMessageChunk,
        AuthMethod,
        ContentBlock,
        JsonRpcErrorCodes,
        PermissionSelected,
        SessionMode,
        SessionModeState,
        StopReason,
        ToolCallStatus,
        ToolCallUpdate,
        ToolCallLocation,
        ToolKind;
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart'
    show SessionPromptRefusal;
import 'package:karmashala_host/src/acp/acp_path_scope.dart';
import 'package:karmashala_host_protocol/protocol.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'acp_fixture.dart';

/// The server's ACP runtime against a scripted agent over in-memory streams
/// (design C4): the conversation as rows, the status as the agent's word,
/// permissions and files answered as the client.
void main() {
  late AppDatabase database;
  late Directory temp;
  late RecordingHost host;

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    temp = Directory.systemTemp.createTempSync('acp_runtime_test');
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

  test('a new session writes the user row and coalesces chunks into one '
      'agent row, told to the transcripts after every write', () async {
    final process = FakeAcpProcess(
      FakeAcpAgent(
        turns: [
          const FakeTurn([
            FakeStep.thought('Let me look.', messageId: 'a1'),
            FakeStep.message('Hello', messageId: 'a1'),
            FakeStep.message(' there.', messageId: 'a1'),
          ]),
        ],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
      mcpUrl: 'http://127.0.0.1:1234/mcp/tok',
    );
    final outcome = await runtime.start();
    expect(outcome.agentSessionId, 'fake-session');
    expect(outcome.resumed, isFalse);
    expect(outcome.notices, isEmpty);
    // What `initialize` announced, and what `session/new` was handed.
    expect(process.agent.initializeParams!['clientInfo'], {
      'name': 'Karmashala',
      'version': kHostVersion,
    });
    expect(process.agent.initializeParams!['clientCapabilities'], {
      'fs': {'readTextFile': true, 'writeTextFile': true},
      'terminal': false,
    });
    final created = process.agent.newSessionParams.single;
    expect(created['cwd'], temp.path);
    expect(created['mcpServers'], [
      {
        'type': 'http',
        'name': 'karmashala',
        'url': 'http://127.0.0.1:1234/mcp/tok',
        'headers': <Object?>[],
      },
    ]);

    await runtime.send('Say hello');
    expect(await runtime.awaitTurn(), StopReason.endTurn);

    final written = rows();
    expect(written.map((r) => r.role), [
      SessionMessageRole.user,
      SessionMessageRole.agent,
    ]);
    expect(written[0].text, 'Say hello');
    expect(written[1].text, 'Hello there.');
    expect(written[1].thinking, 'Let me look.');
    expect(written[1].messageId, 'a1');
    expect(host.messagesChangedCount, greaterThanOrEqualTo(2));
    expect(host.prompts, ['Say hello']);
    expect(statuses(), [
      AgentActivityStatus.idle,
      AgentActivityStatus.working,
      AgentActivityStatus.idle,
    ]);
    expect(host.statuses.last.source, AgentStatusSource.protocol);
    expect(host.statuses.last.sessionId, 'fake-session');
    expect(runtime.tailText(10), ['You: Say hello', 'Agent: Hello there.']);
    await runtime.stop();
  });

  test('a tool call becomes a tool row, patched by id to completed', () async {
    final process = FakeAcpProcess(
      FakeAcpAgent(
        turns: [
          const FakeTurn([
            FakeStep.message('Reading.'),
            FakeStep.toolCall(
              toolCallId: 'c1',
              title: 'Read notes.txt',
              kind: ToolKind.read,
              rawInput: {'path': 'notes.txt'},
              rawOutput: 'the notes',
            ),
            FakeStep.message('Done.'),
          ]),
        ],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
    );
    await runtime.start();
    await runtime.send('Read it');
    await runtime.awaitTurn();

    final written = rows();
    expect(written.map((r) => r.role), [
      SessionMessageRole.user,
      SessionMessageRole.agent,
      SessionMessageRole.tool,
      SessionMessageRole.agent,
    ]);
    final tool = jsonDecode(written[2].toolJson!) as Map;
    expect(tool['toolCallId'], 'c1');
    expect(tool['title'], 'Read notes.txt');
    expect(tool['kind'], 'read');
    expect(tool['status'], 'completed');
    expect(tool['rawInput'], {'path': 'notes.txt'});
    expect(tool['rawOutput'], 'the notes');
    // The tool call closed the first agent row; the second is a new row.
    expect(written[1].text, 'Reading.');
    expect(written[3].text, 'Done.');
    await runtime.stop();
  });

  test('a permission request is a waiting status naming the call; the '
      'approval answers the agent, and the turn runs on to idle', () async {
    final process = FakeAcpProcess(
      FakeAcpAgent(
        turns: [
          const FakeTurn([
            FakeStep.toolCall(
              toolCallId: 'c1',
              title: 'Edit main.dart',
              kind: ToolKind.edit,
              rawInput: {'file_path': 'lib/main.dart'},
              locations: [ToolCallLocation('lib/main.dart', line: 3)],
              permissionOptions: fakePermissionOptions,
            ),
            FakeStep.message('Edited.'),
          ]),
        ],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
      risk: PermissionRisk.ask,
    );
    await runtime.start();
    await runtime.send('Fix it');
    await pump();
    expect(runtime.hasOpenPermission, isTrue);
    expect(runtime.pendingToolCallId, 'c1');
    final waiting = host.statuses.last;
    expect(waiting.status, AgentActivityStatus.awaitingApproval);
    expect(waiting.waiting, AgentWaitKind.approval);
    expect(waiting.hasOpenPrompt, isTrue);
    expect(waiting.toolAsk?.toolName, 'Edit main.dart');
    expect(waiting.toolAsk?.toolUseId, 'c1');
    expect(waiting.toolAsk?.input, {'file_path': 'lib/main.dart'});
    expect(waiting.waitingSince, isNotNull);
    // The edit's checkpoint was noted as the call was announced.
    expect(host.touched, ['lib/main.dart']);

    final answer = await runtime.answerPermission(approve: true);
    expect(answer.answered, 'Allow');
    expect(answer.granted, isTrue);
    expect(answer.effect, contains('Edit main.dart'));
    expect(host.settledCalls, 1);
    expect(host.statuses.last.status, AgentActivityStatus.working);
    expect(await runtime.awaitTurn(), StopReason.endTurn);
    expect(process.agent.permissionOutcomes, [
      const PermissionSelected('allow'),
    ]);
    expect(statuses(), [
      AgentActivityStatus.idle,
      AgentActivityStatus.working,
      AgentActivityStatus.awaitingApproval,
      AgentActivityStatus.working,
      AgentActivityStatus.idle,
    ]);
    final tool = jsonDecode(rows()[1].toolJson!) as Map;
    expect(tool['status'], 'completed');
    await runtime.stop();
  });

  test('a rejection chooses the reject option, and an answer with nothing '
      'open is refused', () async {
    final process = FakeAcpProcess(
      FakeAcpAgent(
        turns: [
          const FakeTurn([
            FakeStep.toolCall(
              toolCallId: 'c1',
              title: 'Run rm -rf',
              kind: ToolKind.execute,
              permissionOptions: fakePermissionOptions,
            ),
          ]),
        ],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
    );
    await runtime.start();
    await expectLater(
      runtime.answerPermission(approve: true),
      throwsA(isA<SessionPromptRefusal>()),
    );
    await runtime.send('Clean up');
    await pump();
    final answer = await runtime.answerPermission(approve: false);
    expect(answer.answered, 'Reject');
    expect(answer.granted, isFalse);
    await runtime.awaitTurn();
    expect(process.agent.permissionOutcomes, [
      const PermissionSelected('reject'),
    ]);
    final tool = jsonDecode(rows()[1].toolJson!) as Map;
    expect(tool['status'], 'failed');
    await runtime.stop();
  });

  test('under autoRun an allow_once option is answered at once', () async {
    final process = FakeAcpProcess(
      FakeAcpAgent(
        turns: [
          const FakeTurn([
            FakeStep.toolCall(
              toolCallId: 'c1',
              title: 'Write out.txt',
              kind: ToolKind.edit,
              permissionOptions: fakePermissionOptions,
            ),
          ]),
        ],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
      risk: PermissionRisk.autoRun,
    );
    await runtime.start();
    await runtime.send('Go');
    expect(await runtime.awaitTurn(), StopReason.endTurn);
    expect(process.agent.permissionOutcomes, [
      const PermissionSelected('allow'),
    ]);
    expect(statuses(), isNot(contains(AgentActivityStatus.awaitingApproval)));
    // The edit still waited for its checkpoint.
    expect(host.settledCalls, 1);
    await runtime.stop();
  });

  test(
    'a refusal stop reason is a failed status carrying the reason',
    () async {
      final process = FakeAcpProcess(
        FakeAcpAgent(
          turns: [
            const FakeTurn([
              FakeStep.message('No.'),
            ], stopReason: StopReason.refusal),
          ],
        ),
      );
      final runtime = runtimeOver(
        process,
        database: database,
        workingDirectory: temp.path,
        host: host,
      );
      await runtime.start();
      await runtime.send('Do something bad');
      expect(await runtime.awaitTurn(), StopReason.refusal);
      final last = host.statuses.last;
      expect(last.status, AgentActivityStatus.failed);
      expect(last.failureReason, 'refusal');
      expect(last.evidence.single, contains('refusal'));
      await runtime.stop();
    },
  );

  test('a cancel ends the turn cancelled and idle, answering an open '
      'permission request cancelled', () async {
    final process = FakeAcpProcess(
      FakeAcpAgent(
        turns: [
          const FakeTurn([
            FakeStep.message('Working...'),
            FakeStep.toolCall(
              toolCallId: 'c1',
              title: 'Edit a.txt',
              kind: ToolKind.edit,
              permissionOptions: fakePermissionOptions,
            ),
            FakeStep.message('never sent'),
          ]),
        ],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
    );
    await runtime.start();
    await runtime.send('Edit');
    await pump();
    expect(runtime.hasOpenPermission, isTrue);
    runtime.cancel();
    expect(await runtime.awaitTurn(), StopReason.cancelled);
    expect(runtime.hasOpenPermission, isFalse);
    expect(runtime.inTurn, isFalse);
    expect(process.agent.cancels, 1);
    expect(host.statuses.last.status, AgentActivityStatus.idle);
    expect(host.statuses.last.detail, 'cancelled');
    expect(rows().map((r) => r.text), ['Edit', 'Working...', '']);
    await runtime.stop();
  });

  test('the process exiting mid-turn fails the turn with its exit code and '
      'stderr, and ends the runtime with that code', () async {
    final process = FakeAcpProcess(
      FakeAcpAgent(
        turns: [
          const FakeTurn([
            FakeStep.message('Starting'),
            FakeStep.waitForCancel(),
          ]),
        ],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
    );
    await runtime.start();
    await runtime.send('Go');
    await pump();
    await process.die(3);
    await runtime.awaitTurn();
    final last = host.statuses.last;
    expect(last.status, AgentActivityStatus.failed);
    expect(last.evidence.single, contains('exit code 3'));
    final end = await runtime.ended;
    expect(end, isA<SessionExited>().having((e) => e.exitCode, 'code', 3));
    expect(runtime.lifecycle.hasEnded, isTrue);
    expect(rows().map((r) => r.text), ['Go', 'Starting']);
    await expectLater(
      runtime.send('again'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('ended'),
        ),
      ),
    );
  });

  test('a second message during a turn is refused in words', () async {
    final process = FakeAcpProcess(
      FakeAcpAgent(
        turns: const [
          FakeTurn([FakeStep.waitForCancel()]),
        ],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
    );
    await runtime.start();
    await runtime.send('First');
    await expectLater(
      runtime.send('Second'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('still working on the last message'),
        ),
      ),
    );
    runtime.cancel();
    await runtime.awaitTurn();
    await runtime.stop();
  });

  test('fs/write_text_file waits for the checkpoint hold, notes the path and '
      'writes under the working directory', () async {
    final process = FakeAcpProcess(
      FakeAcpAgent(
        turns: const [
          FakeTurn([FakeStep.writeFile('out/notes.txt', 'written by agent')]),
        ],
      ),
    );
    host.hold = Completer<void>();
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
    );
    await runtime.start();
    await runtime.send('Write it');
    await settle(const Duration(milliseconds: 50));
    final file = File(p.join(temp.path, 'out', 'notes.txt'));
    expect(file.existsSync(), isFalse, reason: 'held for the checkpoint');
    expect(host.settledCalls, 1);
    host.hold!.complete();
    expect(await runtime.awaitTurn(), StopReason.endTurn);
    expect(file.readAsStringSync(), 'written by agent');
    expect(host.touched, [p.normalize(file.path)]);
    expect(process.agent.fsErrors, isEmpty);
    await runtime.stop();
  });

  test('fs/read_text_file reads under the working directory, by line and '
      'limit, and refuses a path outside it with -32602', () async {
    File(p.join(temp.path, 'a.txt')).writeAsStringSync('one\ntwo\nthree\n');
    final outside = p.join(temp.path, '..', 'elsewhere.txt');
    final process = FakeAcpProcess(
      FakeAcpAgent(
        turns: [
          FakeTurn([
            const FakeStep.readFile('a.txt'),
            const FakeStep.readFile('a.txt', line: 2, limit: 1),
            FakeStep.readFile(outside),
          ]),
        ],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
    );
    await runtime.start();
    await runtime.send('Read');
    await runtime.awaitTurn();
    expect(process.agent.readFileResults, ['one\ntwo\nthree\n', 'two']);
    expect(process.agent.fsErrors, hasLength(1));
    final refusal = process.agent.fsErrors.single as AcpRpcError;
    expect(refusal.code, JsonRpcErrorCodes.invalidParams);
    expect(
      refusal.message,
      contains('outside the session\'s working directory'),
    );
    await runtime.stop();
  });

  test('the mode the risk maps to is set after session/new and announced; '
      'a current_mode_update is announced too', () async {
    const modes = SessionModeState(
      currentModeId: 'default',
      availableModes: [
        SessionMode(id: 'plan', name: 'Plan'),
        SessionMode(id: 'default', name: 'Ask'),
        SessionMode(id: 'acceptEdits', name: 'Accept edits'),
      ],
    );
    final process = FakeAcpProcess(
      FakeAcpAgent(
        modes: modes,
        turns: const [
          FakeTurn([FakeStep.mode('plan')]),
        ],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
      spec: const AcpLaunchSpec(
        modeNames: {
          PermissionRisk.acceptEdits: ['acceptedits'],
        },
      ),
      risk: PermissionRisk.acceptEdits,
      mcpUrl: 'http://127.0.0.1:1/mcp/t',
    );
    final outcome = await runtime.start();
    expect(outcome.notices, isEmpty);
    expect(process.agent.modeChanges, ['acceptEdits']);
    expect(host.modes.last.currentModeId, 'acceptEdits');
    expect(host.modes.last.availableModes.map((m) => m.id), [
      'plan',
      'default',
      'acceptEdits',
    ]);
    expect(runtime.modes?.currentModeId, 'acceptEdits');

    await runtime.send('Plan instead');
    await runtime.awaitTurn();
    expect(host.modes.last.currentModeId, 'plan');

    await runtime.setMode('default');
    expect(process.agent.modeChanges.last, 'default');
    expect(runtime.modes?.currentModeId, 'default');
    await expectLater(
      runtime.setMode('yolo'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('offers no mode "yolo"'),
        ),
      ),
    );
    await runtime.stop();
  });

  test(
    'a risk the agent has no mode for leaves its default and says so',
    () async {
      const modes = SessionModeState(
        currentModeId: 'default',
        availableModes: [SessionMode(id: 'default', name: 'Ask')],
      );
      final process = FakeAcpProcess(FakeAcpAgent(modes: modes));
      final runtime = runtimeOver(
        process,
        database: database,
        workingDirectory: temp.path,
        host: host,
        spec: const AcpLaunchSpec(
          modeNames: {
            PermissionRisk.readOnly: ['plan'],
          },
        ),
        risk: PermissionRisk.readOnly,
        mcpUrl: 'http://127.0.0.1:1/mcp/t',
      );
      final outcome = await runtime.start();
      expect(
        outcome.notices.single,
        contains('offers no mode for "Read-only"'),
      );
      expect(process.agent.modeChanges, isEmpty);
      expect(host.modes.single.currentModeId, 'default');
      await runtime.stop();
    },
  );

  test('session/load continues the row\'s conversation when the agent '
      'advertises it, and its replay writes no rows', () async {
    final process = FakeAcpProcess(
      FakeAcpAgent(
        supportsLoadSession: true,
        loadReplay: const [AgentMessageChunk(ContentBlock.text('old words'))],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
      resumeSessionId: 'earlier-session',
      mcpUrl: 'http://127.0.0.1:1/mcp/t',
    );
    final outcome = await runtime.start();
    expect(outcome.resumed, isTrue);
    expect(outcome.agentSessionId, 'earlier-session');
    expect(
      process.agent.loadSessionParams.single['sessionId'],
      'earlier-session',
    );
    expect(process.agent.loadSessionParams.single['cwd'], temp.path);
    expect(process.agent.newSessionParams, isEmpty);
    expect(rows(), isEmpty);
    await runtime.stop();
  });

  test(
    'without loadSession a resume is a fresh conversation, said in words',
    () async {
      final process = FakeAcpProcess(FakeAcpAgent(supportsLoadSession: false));
      final runtime = runtimeOver(
        process,
        database: database,
        workingDirectory: temp.path,
        host: host,
        resumeSessionId: 'earlier-session',
      );
      final outcome = await runtime.start();
      expect(outcome.resumed, isFalse);
      expect(outcome.agentSessionId, 'fake-session');
      expect(outcome.notices, [
        contains("Karmashala's tools were not handed"),
        contains('cannot reload a conversation over ACP'),
      ]);
      await runtime.stop();
    },
  );

  test('an agent demanding authentication is authenticated with the one '
      'method it advertises, and session/new retried', () async {
    final process = FakeAcpProcess(
      FakeAcpAgent(
        requireAuthentication: true,
        authMethods: const [AuthMethod(id: 'login', name: 'Log in')],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
    );
    await runtime.start();
    expect(process.agent.authenticatedWith, 'login');
    expect(process.agent.receivedMethods, [
      'initialize',
      'session/new',
      'authenticate',
      'session/new',
    ]);
    await runtime.stop();
  });

  test('several methods and no preference refuse the start in words, and '
      'the runtime ends', () async {
    final process = FakeAcpProcess(
      FakeAcpAgent(
        requireAuthentication: true,
        authMethods: const [
          AuthMethod(id: 'a', name: 'A'),
          AuthMethod(id: 'b', name: 'B'),
        ],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
    );
    await expectLater(
      runtime.start(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('offers 2 methods'), contains('a, b')),
        ),
      ),
    );
    expect(runtime.lifecycle.hasEnded, isTrue);
    await pump();
    expect(process.killed, isTrue);
  });

  test('stop cancels the open turn, closes the peer and kills a process '
      'that does not exit', () async {
    final process = FakeAcpProcess(
      FakeAcpAgent(
        turns: const [
          FakeTurn([FakeStep.waitForCancel()]),
        ],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
    );
    await runtime.start();
    await runtime.send('Go');
    await pump();
    runtime.markCloseRequested();
    final end = await runtime.stop();
    expect(process.killed, isTrue);
    expect(end, isA<SessionExited>().having((e) => e.exitCode, 'code', 137));
    expect(runtime.closeRequested, isTrue);
  });

  test('an edit whose kind and file arrive on a later tool_call_update still '
      'reaches the checkpoint, once', () async {
    final process = FakeAcpProcess(
      FakeAcpAgent(
        turns: const [
          FakeTurn([
            FakeStep.update(
              ToolCallUpdate(
                toolCallId: 'c1',
                isNew: true,
                title: 'Write',
                status: ToolCallStatus.pending,
              ),
            ),
            FakeStep.update(
              ToolCallUpdate(
                toolCallId: 'c1',
                kind: ToolKind.edit,
                status: ToolCallStatus.inProgress,
                locations: [ToolCallLocation('/tmp/work/note.txt')],
              ),
            ),
            FakeStep.update(
              ToolCallUpdate(
                toolCallId: 'c1',
                status: ToolCallStatus.completed,
                locations: [ToolCallLocation('/tmp/work/note.txt')],
              ),
            ),
          ]),
        ],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: '/tmp/work',
      host: host,
    );
    await runtime.start();
    await runtime.send('Write it');
    expect(await runtime.awaitTurn(), StopReason.endTurn);
    expect(host.touched, ['/tmp/work/note.txt']);
    final tool = jsonDecode(rows()[1].toolJson!) as Map;
    expect(tool['kind'], 'edit');
    expect(tool['status'], 'completed');
    await runtime.stop();
  });

  test('a WSL agent\'s fs/* paths are checked in POSIX spelling and reach '
      'this machine through the environment\'s mapping; the checkpoint hears '
      'the agent\'s spelling', () async {
    File(p.join(temp.path, 'a.txt')).writeAsStringSync('alpha');
    final process = FakeAcpProcess(
      FakeAcpAgent(
        turns: const [
          FakeTurn([
            FakeStep.readFile('/tmp/work/a.txt'),
            FakeStep.writeFile('out/b.txt', 'beta'),
            FakeStep.readFile('/etc/passwd'),
          ]),
        ],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: '/tmp/work',
      host: host,
      files: AcpPathScope(
        root: '/tmp/work',
        context: p.posix,
        toHost: (path) =>
            p.join(temp.path, p.posix.relative(path, from: '/tmp/work')),
      ),
    );
    await runtime.start();
    await runtime.send('Go');
    expect(await runtime.awaitTurn(), StopReason.endTurn);
    expect(process.agent.readFileResults, ['alpha']);
    expect(File(p.join(temp.path, 'out', 'b.txt')).readAsStringSync(), 'beta');
    expect(host.touched, ['/tmp/work/out/b.txt']);
    expect(process.agent.fsErrors, hasLength(1));
    final refusal = process.agent.fsErrors.single as AcpRpcError;
    expect(refusal.code, JsonRpcErrorCodes.invalidParams);
    expect(refusal.message, contains('/tmp/work'));
    await runtime.stop();
  });
}
