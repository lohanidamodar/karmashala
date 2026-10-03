import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_acp/karmashala_acp.dart'
    show
        ConfigOption,
        ConfigSelectOption,
        SessionMode,
        SessionModeState,
        StopReason,
        ToolKind;
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/acp/acp_runtime_host.dart';
import 'package:karmashala_host/src/acp/acp_session_modes.dart';
import 'package:karmashala_host/src/acp/acp_session_runtime.dart';
import 'package:karmashala_host/src/sessions/session_input.dart';
import 'package:karmashala_host/src/status/daemon_agent_status.dart';
import 'package:karmashala_host/src/status/daemon_prompt_answers.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'acp_fixture.dart';

/// The status the runtime reports reaches the daemon's keeper as the agent's
/// word; a client's send, Stop and approval reach the runtime; a decision is
/// filed; `sessions.setMode` lands on the agent.
void main() {
  final t0 = DateTime.utc(2026, 10, 2, 12);

  late AppDatabase database;
  late SessionRegistry registry;
  late DaemonAgentStatus status;
  late DaemonPromptAnswers prompts;
  late List<(String, Map<String, Object?>?)> published;
  late List<DecisionRecord> decisions;
  late Directory temp;

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
      ['a1', AgentIds.claudeAcp, 'local', '/bin/claude-agent-acp', '$t0', 1],
    );
    SessionDao(database).insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Fix the cart',
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: t0,
      ),
    );
    registry = SessionRegistry(launcher: FakePtyLauncher());
    published = [];
    status = DaemonAgentStatus(
      registry: registry,
      database: database,
      publish: (id, body) => published.add((id, body)),
      interval: const Duration(hours: 1),
    );
    decisions = [];
    prompts = DaemonPromptAnswers(
      status: status,
      database: database,
      onDecision: decisions.add,
    );
    temp = Directory.systemTemp.createTempSync('acp_routing_test');
  });

  tearDown(() async {
    await status.close();
    await registry.shutdown();
    database.close();
    temp.deleteSync(recursive: true);
  });

  /// A runtime whose status goes to the daemon, as the server wires it.
  Future<AcpSessionRuntime> open(FakeAcpProcess process) async {
    final runtime = registry.openAcp(
      'karmashala_s1',
      runtimeOver(
        process,
        database: database,
        workingDirectory: temp.path,
        host: _DaemonHost(status),
      ),
    );
    await runtime.start();
    status.tick();
    return runtime;
  }

  AgentStatusReport report() => status.statusOf('s1')!.report;

  test('the runtime\'s word is the session\'s status, published as protocol, '
      'and the daemon holds the session without a screen', () async {
    final process = FakeAcpProcess(
      FakeAcpAgent(
        turns: [
          const FakeTurn([
            FakeStep.toolCall(
              toolCallId: 'c1',
              title: 'Edit cart.dart',
              kind: ToolKind.edit,
              permissionOptions: fakePermissionOptions,
            ),
          ]),
        ],
      ),
    );
    final runtime = await open(process);
    expect(status.holds('s1'), isTrue);
    expect(status.runsHere('s1'), isTrue);
    expect(status.runningSessionOf('s1'), isNull);
    expect(status.acpRuntimeOf('s1'), same(runtime));
    expect(status.liveScreenOf('s1'), same(runtime));
    expect(status.typeAsServer('s1', [13]), isFalse);
    expect(report().status, AgentActivityStatus.idle);
    expect(report().source, AgentStatusSource.protocol);
    expect(prompts.holds('s1'), isTrue);

    await runtime.send('Fix it');
    await pump();
    expect(report().status, AgentActivityStatus.awaitingApproval);
    expect(report().hasOpenPrompt, isTrue);
    expect(report().toolAsk?.toolName, 'Edit cart.dart');
    expect(report().toolAsk?.toolUseId, 'c1');
    expect(report().waitingSince, isNotNull);
    // A tick in between reads no screen and forgets nothing.
    status.tick();
    expect(report().status, AgentActivityStatus.awaitingApproval);
    expect(published.last.$2?['sessionId'], 's1');

    final evidence = await prompts.evidence('s1');
    expect(evidence.approve?.label, 'Allow');
    expect(evidence.deny?.label, 'Reject');
    expect(evidence.menu, isNull);

    final answer = await prompts.answer(
      ApprovalAnswerRequest(
        sessionId: 's1',
        approve: true,
        ask: PromptAsk(toolUseId: 'c1', waitingSince: report().waitingSince),
        decidedBy: 'the user',
      ),
    );
    expect(answer.answered, 'Allow');
    expect(await runtime.awaitTurn(), StopReason.endTurn);
    expect(report().status, AgentActivityStatus.idle);
    expect(report().toolAsk, isNull);
    expect(decisions.single.kind, DecisionKind.approvalGranted);
    expect(decisions.single.summary, contains('Edit cart.dart'));
    expect(decisions.single.decidedBy, 'the user');
    expect(decisions.single.origin, DecisionOrigin.approvalPrompt);

    await process.die(0);
    await runtime.ended;
    status.tick();
    expect(status.statusOf('s1'), isNull);
    expect(status.holds('s1'), isFalse);
  });

  test('an answer naming another call is refused as stale, and one with no '
      'request open is refused', () async {
    final process = FakeAcpProcess(
      FakeAcpAgent(
        turns: [
          const FakeTurn([
            FakeStep.toolCall(
              toolCallId: 'c1',
              title: 'Run tests',
              kind: ToolKind.execute,
              permissionOptions: fakePermissionOptions,
            ),
          ]),
        ],
      ),
    );
    final runtime = await open(process);
    await expectLater(
      prompts.answer(
        const ApprovalAnswerRequest(sessionId: 's1', approve: true),
      ),
      throwsA(isA<SessionPromptRefusal>()),
    );
    await runtime.send('Test');
    await pump();
    await expectLater(
      prompts.answer(
        const ApprovalAnswerRequest(
          sessionId: 's1',
          approve: true,
          ask: PromptAsk(toolUseId: 'c-other'),
        ),
      ),
      throwsA(
        isA<SessionPromptRefusal>().having((r) => r.stale, 'stale', true),
      ),
    );
    await expectLater(
      prompts.answer(
        const MenuAnswerRequest(sessionId: 's1', menuId: 'm', option: 0),
      ),
      throwsA(isA<SessionPromptRefusal>()),
    );
    final frame = await prompts.answerFrame(7, {
      'kind': 'approval',
      'sessionId': 's1',
      'approve': false,
    });
    expect(frame.requestId, 7);
    expect(frame.answered, 'Reject');
    await runtime.awaitTurn();
    expect(decisions.single.kind, DecisionKind.approachRejected);
  });

  test('a client\'s send is the next prompt, refused while a turn is open; '
      'Stop is a cancel', () async {
    final process = FakeAcpProcess(
      FakeAcpAgent(
        turns: const [
          FakeTurn([FakeStep.message('hi'), FakeStep.waitForCancel()]),
          FakeTurn([FakeStep.message('again')]),
        ],
      ),
    );
    final runtime = await open(process);
    final input = SessionInput(
      prompts: prompts,
      typist: SessionMessageTypist(
        readScreen: (_) => null,
        markersFor: (_) => null,
        type: (_, _) => false,
        press: (_, _) => false,
      ),
    );
    final sent = await input.handle(
      const SessionSend(sessionId: 's1', text: 'First'),
      null,
    );
    expect(sent, isA<SessionSent>().having((s) => s.via, 'via', 'protocol'));
    await pump();
    expect(process.agent.prompts.single.single.toJson()['text'], 'First');
    await expectLater(
      input.handle(const SessionSend(sessionId: 's1', text: 'Second'), null),
      throwsA(
        isA<DataRefused>()
            .having((r) => r.code, 'code', DataRefusalCode.conflict)
            .having((r) => r.message, 'message', contains('still working')),
      ),
    );
    await input.handle(const SessionInterrupt('s1'), null);
    expect(await runtime.awaitTurn(), StopReason.cancelled);
    expect(process.agent.cancels, 1);
    await input.handle(
      const SessionSend(sessionId: 's1', text: 'Second'),
      null,
    );
    expect(await runtime.awaitTurn(), StopReason.endTurn);
    expect(process.agent.prompts, hasLength(2));
    final rows = SessionMessageDao(database).listAfter('s1');
    expect(rows.map((r) => r.text), ['First', 'hi', 'Second', 'again']);
  });

  test('sessions.setMode reaches the agent for an ACP session and is refused '
      'in words for any other', () async {
    const modes = SessionModeState(
      currentModeId: 'default',
      availableModes: [
        SessionMode(id: 'plan', name: 'Plan'),
        SessionMode(id: 'default', name: 'Ask'),
      ],
    );
    final process = FakeAcpProcess(FakeAcpAgent(modes: modes));
    await open(process);
    final changer = AcpSessionModes(runtimeOf: status.acpRuntimeOf);
    await changer.setMode('s1', 'plan');
    expect(process.agent.modeChanges, ['plan']);
    await expectLater(
      changer.setMode('s1', 'yolo'),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.code,
          'code',
          DataRefusalCode.invalid,
        ),
      ),
    );
    await expectLater(
      changer.setMode('nope', 'plan'),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.code,
          'code',
          DataRefusalCode.notFound,
        ),
      ),
    );
  });

  test('sessions.setConfigOption reaches the agent, is refused in words for '
      'a value it does not offer, and the greeting tells a late client what '
      'runs here', () async {
    const modes = SessionModeState(
      currentModeId: 'agent',
      availableModes: [SessionMode(id: 'agent', name: 'Agent')],
    );
    const options = [
      ConfigOption(
        id: 'model',
        name: 'Model',
        type: 'select',
        currentValue: 'sonnet',
        options: [
          ConfigSelectOption(value: 'sonnet', name: 'Sonnet'),
          ConfigSelectOption(value: 'opus', name: 'Opus'),
        ],
      ),
    ];
    final process = FakeAcpProcess(
      FakeAcpAgent(modes: modes, configOptions: options),
    );
    final runtime = await open(process);
    final changer = AcpSessionModes(
      runtimeOf: status.acpRuntimeOf,
      running: () => registry.acpRuntimes,
    );

    final greeting = changer.greeting();
    expect(
      greeting.whereType<SessionModesChanged>().single.currentModeId,
      'agent',
    );
    expect(
      greeting
          .whereType<SessionConfigOptionsChanged>()
          .single
          .option('model')
          ?.currentValue,
      'sonnet',
    );

    await changer.setConfigOption('s1', 'model', 'opus');
    expect(process.agent.configChanges.single['value'], 'opus');
    expect(runtime.configOptions?.option('model')?.currentValue, 'opus');
    await expectLater(
      changer.setConfigOption('s1', 'model', 'haiku'),
      throwsA(
        isA<DataRefused>()
            .having((r) => r.code, 'code', DataRefusalCode.invalid)
            .having((r) => r.message, 'message', contains('offers no "haiku"')),
      ),
    );
    await expectLater(
      changer.setConfigOption('nope', 'model', 'opus'),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.code,
          'code',
          DataRefusalCode.notFound,
        ),
      ),
    );

    await runtime.stop();
    expect(changer.greeting(), isEmpty);
  });
}

/// The server's host for a runtime, cut to what these cases observe.
final class _DaemonHost extends AcpRuntimeHost {
  const _DaemonHost(this._status);

  final DaemonAgentStatus _status;

  @override
  void status(String sessionId, AgentStatusReport report) =>
      _status.report(sessionId, report);

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
