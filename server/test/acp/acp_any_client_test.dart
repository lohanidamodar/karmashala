import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart' show PathProbe;
import 'package:karmashala_acp/karmashala_acp.dart' show AuthMethod;
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart' show DataService;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/acp/acp_runtimes.dart';
import 'package:karmashala_host/src/acp/acp_session_runtime.dart';
import 'package:karmashala_host/src/automations/daemon_agents.dart';
import 'package:karmashala_host/src/automations/daemon_checkout_facts.dart';
import 'package:karmashala_host/src/automations/hosted_agent_launcher.dart';
import 'package:karmashala_host/src/mcp/tools/server_tool_context.dart';
import 'package:karmashala_host/src/mcp/tools/session_tool_set.dart';
import 'package:karmashala_host/src/serve/server_features.dart';
import 'package:karmashala_host/src/sessions/launch/server_session_launcher.dart';
import 'package:karmashala_host/src/sessions/session_ends_with_server.dart';
import 'package:karmashala_host/src/sessions/session_input.dart';
import 'package:karmashala_host/src/status/daemon_agent_status.dart';
import 'package:karmashala_host/src/status/daemon_prompt_answers.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'acp_fixture.dart';

final class _Everywhere implements PathProbe {
  const _Everywhere();
  @override
  bool? fileExists(String path) => true;
  @override
  bool isLink(String path) => false;
  @override
  String? linkTarget(String path) => null;
}

/// The runtime's word reaches the daemon's keeper, as `ServerAcpHost` does.
class _StatusHost extends RecordingHost {
  _StatusHost(this._status);
  final DaemonAgentStatus _status;
  @override
  void status(String sessionId, AgentStatusReport report) {
    super.status(sessionId, report);
    _status.report(sessionId, report);
  }
}

/// **Any connected client works with an ACP session as with a terminal
/// one.** A message to one nothing runs — from a phone or another desktop
/// (`sessions.send`), or an agent (`session_send`) — resumes it here first
/// (`session/load`, or a fresh conversation in the same row with its
/// notice) and is its next turn; a resume refused is said in words and
/// nothing is sent. An agent reads its conversation (`session_transcript`)
/// from the rows the server keeps and answers its permission prompts
/// (`session_answer`). A terminal row is untouched by any of it.
void main() {
  final t0 = DateTime.utc(2026, 10, 2, 12);

  late AppDatabase database;
  late SessionRegistry registry;
  late Directory temp;
  late List<AcpSessionStart> starts;
  late FakeAcpAgent agent;
  late DaemonAgentStatus status;
  late DaemonPromptAnswers prompts;
  late ServerSessionLauncher launches;

  Session row(
    String id, {
    String installation = 'acp1',
    SessionStatus status = SessionStatus.completed,
    String? conversation = 'agent-session-9',
  }) {
    final session = Session(
      id: id,
      repositoryId: 'r1',
      agentInstallationId: installation,
      title: 'Work $id',
      useWorktree: false,
      status: status,
      createdAt: t0,
      externalSessionId: conversation,
    );
    SessionDao(database).insert(session);
    return session;
  }

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    temp = Directory.systemTemp.createTempSync('acp_any_client_test');
    final local = Platform.isWindows ? 'windowsNative' : 'localPosix';
    database.execute(
      'INSERT INTO execution_environments (id, kind, name, created_at) '
      'VALUES (?, ?, ?, ?);',
      ['local', local, 'Here', '$t0'],
    );
    database.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, '
      'path, created_at) VALUES (?, ?, ?, ?, ?, ?);',
      ['r1', 'p1', 'shop', 'local', temp.path, '$t0'],
    );
    database.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at, executable_by_user) '
      'VALUES (?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?);',
      [
        'acp1', AgentIds.grok, 'local', 'npx.cmd', '$t0', 1, //
        'cc1', AgentIds.claudeCode, 'local', '/bin/claude', '$t0', 1,
      ],
    );
    registry = SessionRegistry(launcher: FakePtyLauncher());
    status = DaemonAgentStatus(
      registry: registry,
      database: database,
      publish: (_, _) {},
      interval: const Duration(hours: 1),
    );
    prompts = DaemonPromptAnswers(status: status, database: database);
    starts = [];
    agent = FakeAcpAgent(
      sessionIdPrefix: 'agent-session',
      turns: const [
        FakeTurn([FakeStep.message('Back on it')]),
        FakeTurn([FakeStep.message('And again')]),
      ],
    );
    final rows = CheckoutRows(database);
    launches = ServerSessionLauncher(
      launcher: HostedAgentLauncher(
        registry: registry,
        sessions: SessionDao(database),
        mcp: SessionMcpAccessPoint(mcp: null, configDirectory: temp.path),
        now: () => t0,
        newId: () => 'new',
        hostEnvironment: const {},
        environmentOf: rows.environment,
        acpRuntimes: (start) {
          starts.add(start);
          return runtimeOver(
            FakeAcpProcess(agent),
            database: database,
            workingDirectory: start.directory.path,
            host: _StatusHost(status),
            sessionId: start.sessionId,
            agentId: start.agentId,
            spec: start.spec,
            resumeSessionId: start.resumeSessionId,
          );
        },
        windows: false,
      ),
      registry: registry,
      sessions: SessionDao(database),
      rows: rows,
      facts: DaemonCheckoutFacts(rows, windows: Platform.isWindows),
      installationsIn: DataService(database).installationsIn,
      pathProbe: const _Everywhere(),
      directoryPresent: (_) => true,
    );
  });

  tearDown(() async {
    await status.close();
    await registry.shutdown();
    database.close();
    temp.deleteSync(recursive: true);
  });

  /// `sessions.send` and `.interrupt`, wired as `serve` wires them.
  SessionInput input({void Function(String)? log}) => SessionInput(
    log: log,
    prompts: prompts,
    typist: SessionToolSet.typistOver(prompts),
    resumesOnSend: sessionSpeaksAcp(
      rows: CheckoutRows(database),
      agents: const DaemonAgents(),
      sessionOf: SessionDao(database).getById,
    ),
    resume: (sessionId, prompt) => launches.resume(sessionId, prompt: prompt),
  );

  /// The MCP session tools, wired as `serve` wires them.
  SessionToolSet tools() => SessionToolSet(
    ServerToolContext(
      database: database,
      data: DataService(database),
      dataDirectory: temp.path,
    ),
    prompts: prompts,
    registry: registry,
    resumeWith: (sessionId, prompt) async {
      await launches.resume(sessionId, prompt: prompt);
    },
  );

  AcpSessionRuntime runtimeOf(String id) => registry.findAcp('karmashala_$id')!;

  List<String> conversation(String id) => [
    for (final message in SessionMessageDao(database).listAfter(id))
      message.text,
  ];

  test('the server announces that a send resumes', () {
    expect(kServerFeatures, contains('sessions.send.resumes'));
  });

  test('the server announces each ACP request family it serves', () {
    expect(
      kServerFeatures,
      containsAll([
        'sessions.setMode',
        'sessions.setConfigOption',
        'acpAgents',
        'acpAgents.install',
        'acpAuth',
      ]),
    );
  });

  group('sessions.send — a phone, another desktop', () {
    test(
      'to an ended ACP session resumes it with session/load and sends the '
      'message as its next turn; answered resumed, with the notice',
      () async {
        row('old');

        final sent = await input().handle(
          const SessionSend(
            sessionId: 'old',
            text: 'carry on',
            requestId: 'r1',
          ),
          'phone-1',
        );

        expect(sent, isA<SessionSent>());
        sent as SessionSent;
        expect(sent.sent, isTrue);
        expect(sent.via, SessionInput.viaProtocol);
        expect(sent.resumed, isTrue);
        // This server serves no MCP endpoint here: the start says so.
        expect(sent.notice, contains("Karmashala's tools were not handed"));
        expect(agent.loadSessionParams.single['sessionId'], 'agent-session-9');
        expect(agent.newSessionParams, isEmpty);
        await runtimeOf('old').awaitTurn();
        expect(conversation('old'), ['carry on', 'Back on it']);
        expect(
          SessionDao(database).getById('old')!.status,
          SessionStatus.running,
        );

        // The wire carries both, and an older reader's fields are unchanged.
        final wire = SessionSent.fromJson(sent.toJson());
        expect(wire.resumed, isTrue);
        expect(wire.notice, sent.notice);
        expect(const SessionSent(sent: true, via: 'readBack').toJson(), {
          'sent': true,
          'via': 'readBack',
        });
      },
    );

    test('to one that runs is sent as it is: no second resume', () async {
      row('old');
      final client = input();
      await client.handle(
        const SessionSend(sessionId: 'old', text: 'carry on'),
        null,
      );
      await runtimeOf('old').awaitTurn();

      final again =
          await client.handle(
                const SessionSend(sessionId: 'old', text: 'and then'),
                null,
              )
              as SessionSent;

      expect(again.resumed, isFalse);
      expect(starts, hasLength(1));
      await runtimeOf('old').awaitTurn();
      expect(conversation('old'), [
        'carry on',
        'Back on it',
        'and then',
        'And again',
      ]);
    });

    test('an agent that cannot load starts a fresh conversation in the same '
        'row, says so, and takes the message', () async {
      agent = FakeAcpAgent(
        sessionIdPrefix: 'agent-session',
        supportsLoadSession: false,
        turns: const [
          FakeTurn([FakeStep.message('Fresh start')]),
        ],
      );
      row('old');

      final sent =
          await input().handle(
                const SessionSend(sessionId: 'old', text: 'carry on'),
                null,
              )
              as SessionSent;

      expect(sent.resumed, isTrue);
      expect(sent.notice, contains('fresh conversation in the same session'));
      expect(agent.newSessionParams, hasLength(1));
      await runtimeOf('old').awaitTurn();
      expect(conversation('old'), ['carry on', 'Fresh start']);
    });

    test(
      'a resume refused is said in its words, and nothing is sent',
      () async {
        row('old');
        // The checkout it ran in is gone from the workspace.
        database.execute(
          'UPDATE sessions SET repository_id = ? WHERE id = ?;',
          ['gone', 'old'],
        );

        await expectLater(
          input().handle(
            const SessionSend(sessionId: 'old', text: 'carry on'),
            null,
          ),
          throwsA(
            isA<DataRefused>()
                .having((r) => r.code, 'code', DataRefusalCode.failed)
                .having(
                  (r) => r.message,
                  'message',
                  allOf(
                    contains('could not be resumed'),
                    contains('not in the workspace any more'),
                  ),
                ),
          ),
        );
        expect(starts, isEmpty);
        expect(agent.prompts, isEmpty);
      },
    );

    test('to a start that was refused — failed, no conversation named — '
        'starts a fresh conversation in the same row and takes the '
        'message', () async {
      row('refused', status: SessionStatus.failed, conversation: null);

      final sent =
          await input().handle(
                const SessionSend(sessionId: 'refused', text: 'try again'),
                null,
              )
              as SessionSent;

      expect(sent.sent, isTrue);
      expect(sent.resumed, isTrue);
      expect(agent.newSessionParams, hasLength(1));
      expect(agent.loadSessionParams, isEmpty);
      await runtimeOf('refused').awaitTurn();
      expect(conversation('refused'), ['try again', 'Back on it']);
    });

    test('to a start refused for a login that this server still holds '
        'starts it again; refused again, the agent\'s words reach the '
        'sender, and a retry of the same key is tried again', () async {
      // A fake agent serves one process; each start gets its own.
      FakeAcpAgent refusing() => FakeAcpAgent(
        requireAuthentication: true,
        authMethods: const [
          AuthMethod(id: 'a', name: 'A'),
          AuthMethod(id: 'b', name: 'B'),
        ],
      );
      agent = refusing();
      row('refused', status: SessionStatus.failed, conversation: null);
      await expectLater(
        launches.resume('refused', prompt: 'hello'),
        throwsA(isA<StateError>()),
      );
      expect(
        SessionDao(database).getById('refused')!.status,
        SessionStatus.failed,
      );
      final logged = <String>[];
      final client = input(log: logged.add);
      const send = SessionSend(
        sessionId: 'refused',
        text: 'try again',
        requestId: 'k1',
      );

      for (var attempt = 2; attempt <= 3; attempt++) {
        agent = refusing();
        await expectLater(
          client.handle(send, null),
          throwsA(
            isA<DataRefused>()
                .having((r) => r.code, 'code', DataRefusalCode.failed)
                .having(
                  (r) => r.message,
                  'message',
                  contains('asks to be logged in first'),
                ),
          ),
        );
        expect(starts, hasLength(attempt));
      }
      expect(conversation('refused'), isEmpty);
      // The server's log says so too, not only the sender's snackbar.
      expect(logged, [
        for (var i = 0; i < 2; i++) ...[
          contains('resuming it at the server to take the message'),
          allOf(
            startsWith('sessions.send refused refused:'),
            contains('asks to be logged in first'),
          ),
        ],
      ]);
    });

    test(
      'a terminal session nothing runs is not resumed: not running here',
      () async {
        row('pty', installation: 'cc1');

        await expectLater(
          input().handle(const SessionSend(sessionId: 'pty', text: 'hi'), null),
          throwsA(
            isA<DataRefused>()
                .having((r) => r.code, 'code', DataRefusalCode.notFound)
                .having((r) => r.message, 'message', contains('not running')),
          ),
        );
        expect(starts, isEmpty);
      },
    );

    test('Stop to an ACP session nothing runs has nothing to stop', () async {
      row('old');
      await expectLater(
        input().handle(const SessionInterrupt('old'), null),
        throwsA(
          isA<DataRefused>().having(
            (r) => r.code,
            'code',
            DataRefusalCode.notFound,
          ),
        ),
      );
      expect(starts, isEmpty);
    });
  });

  group('the MCP session tools — an agent', () {
    test(
      'session_send to an ended ACP session resumes it and sends; '
      'session_transcript reads its conversation from the server\'s rows',
      () async {
        row('old');
        final set = tools();

        final sent = await set.call('session_send', {
          'sessionId': 'old',
          'text': 'carry on',
        }, null)!;

        expect(sent, containsPair('delivered', true));
        expect(sent, containsPair('resumed', true));
        expect(agent.loadSessionParams.single['sessionId'], 'agent-session-9');
        await runtimeOf('old').awaitTurn();

        final read =
            await set.call('session_transcript', {'sessionId': 'old'}, null)!
                as Map<String, Object?>;
        final turns = (read['turns']! as List).cast<Map<String, Object?>>();
        expect(turns.map((t) => '${t['role']}: ${t['text']}'), [
          'user: carry on',
          'agent: Back on it',
        ]);
        expect(read['turnsSource'], contains('ACP'));
        expect(read['live'], isTrue);
      },
    );

    test('session_answer approves an ACP permission prompt, and the turn '
        'goes on', () async {
      agent = FakeAcpAgent(
        sessionIdPrefix: 'agent-session',
        turns: const [
          FakeTurn([
            FakeStep.toolCall(
              toolCallId: 'c1',
              title: 'Run tests',
              permissionOptions: fakePermissionOptions,
            ),
            FakeStep.message('Tests pass.'),
          ]),
        ],
      );
      row('old');
      await input().handle(
        const SessionSend(sessionId: 'old', text: 'run them'),
        null,
      );
      final runtime = runtimeOf('old');
      while (!runtime.hasOpenPermission) {
        await pump();
      }

      final answered = await tools().call('session_answer', {
        'sessionId': 'old',
        'decision': 'approve',
      }, 'caller-1')!;

      expect(answered, containsPair('sessionId', 'old'));
      expect((answered as Map)['effect'], contains('Allowed "Run tests"'));
      await runtime.awaitTurn();
      expect(
        conversation('old'),
        containsAllInOrder(['run them', 'Tests pass.']),
      );
    });
  });
}
