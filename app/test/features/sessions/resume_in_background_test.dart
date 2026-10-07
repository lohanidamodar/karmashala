import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/stream.dart' show FakeChatProtocol;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/explorer/application/explorer_actions.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_engine_provider.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/session.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// **Resuming from the Agent dashboard keeps the person where they are**:
/// the session comes back at the server — idle, or with a message as its
/// next turn — and no tab opens, nothing is selected, focus stays put.
void main() {
  late TestMachine db;
  late FakeDataServer server;

  setUp(() {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation(id: 'pty'));
    server.installationRows.insert(
      agentInstallation(
        id: 'acp',
        agentId: AgentIds.claudeAcp,
        path: r'C:\Users\me\.bin\claude-agent-acp.exe',
      ),
    );
    server.sessionWork.typesSends = true;
  });

  Future<ProviderContainer> connect() async {
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        ...fakeTerminalOverrides(machine: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        serverOfferProvider.overrideWithValue(
          const ServerOffer(
            sameMachine: true,
            serverOs: 'windows',
            features: {'sessions.send', 'sessions.interrupt'},
          ),
        ),
        sessionRunningOnHostProvider.overrideWithValue(
          (id) => server.sessionWork.running.contains(id),
        ),
        chatProtocolResolverProvider.overrideWithValue(
          (agentId) => FakeChatProtocol(agentId: agentId),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  List<SessionStartSpec> starts() => [
    for (final request in server.sessionWork.asked)
      if (request is SessionStart) request.spec,
  ];

  List<SessionResume> resumes() => [
    for (final request in server.sessionWork.asked)
      if (request is SessionResume) request,
  ];

  void endedTerminal({bool archived = false}) => db.server.sessionRows.insert(
    session(
      id: 'pty-1',
      agentInstallationId: 'pty',
      status: SessionStatus.completed,
    ).copyWith(
      externalSessionId: 'conv-1',
      archivedAt: archived ? testTime : null,
    ),
  );

  void endedChat() => db.server.sessionRows.insert(
    session(
      id: 'acp-1',
      agentInstallationId: 'acp',
      status: SessionStatus.completed,
    ),
  );

  /// Nothing opened in this window and nothing was selected.
  void expectStayedPut(ProviderContainer container) {
    expect(container.read(terminalSessionsControllerProvider).tabs, isEmpty);
    expect(container.read(selectedSessionIdProvider), isNull);
    expect(container.read(sessionsStartingProvider), isEmpty);
  }

  test('Resume brings a terminal session back idle, with no tab', () async {
    endedTerminal();
    final container = await connect();

    final result = await container
        .read(explorerActionsProvider)
        .resumeInBackground('pty-1');

    expect(result.outcome, ExplorerOutcome.resumed);
    final spec = starts().single;
    expect(spec.resumeConversationId, 'conv-1');
    expect(spec.newSession, isFalse);
    expect(spec.prompt, isNull);
    expect(server.sessionWork.running, {'pty-1'});
    expect(server.sessionWork.sent, isEmpty);
    expectStayedPut(container);
  });

  test('Resume and send delivers the message as its first prompt, with no '
      'tab', () async {
    endedTerminal();
    final container = await connect();

    final result = await container
        .read(explorerActionsProvider)
        .resumeInBackground('pty-1', message: '  pick up the tests  ');

    expect(result.outcome, ExplorerOutcome.resumed);
    expect(starts().single.prompt, 'pick up the tests');
    expect(server.sessionWork.running, {'pty-1'});
    expectStayedPut(container);
  });

  test('typing to a stopped session from the peek resumes it in the '
      'background', () async {
    endedTerminal();
    final container = await connect();

    await container
        .read(sessionActionsProvider)
        .continueInBackground('pty-1', 'and the docs');

    expect(starts().single.prompt, 'and the docs');
    expectStayedPut(container);
  });

  test('a chat session is resumed at the server idle, its chat tab not '
      'opened', () async {
    endedChat();
    final container = await connect();

    final result = await container
        .read(explorerActionsProvider)
        .resumeInBackground('acp-1');

    expect(result.outcome, ExplorerOutcome.resumed);
    expect(resumes().map((r) => r.sessionId), ['acp-1']);
    expect(server.sessionWork.running, {'acp-1'});
    expect(server.sessionWork.sent, isEmpty);
    expectStayedPut(container);
  });

  test('a chat session resumed with a message is sent it, its chat tab not '
      'opened', () async {
    endedChat();
    final container = await connect();

    await container
        .read(explorerActionsProvider)
        .resumeInBackground('acp-1', message: 'carry on');

    expect(resumes().map((r) => r.sessionId), ['acp-1']);
    expect(server.sessionWork.sent.single.text, 'carry on');
    expectStayedPut(container);
  });

  test(
    'an archived session is unarchived first, and the result says so',
    () async {
      endedTerminal(archived: true);
      final container = await connect();

      final result = await container
          .read(explorerActionsProvider)
          .resumeInBackground('pty-1');

      expect(db.server.sessionRows.getById('pty-1')!.isArchived, isFalse);
      expect(result.outcome, ExplorerOutcome.resumed);
      expect(result.message, contains('unarchived'));
      expect(starts().single.resumeConversationId, 'conv-1');
      expectStayedPut(container);
    },
  );

  test('one already running is left as it is: nothing starts twice', () async {
    endedTerminal();
    final container = await connect();
    await container.read(explorerActionsProvider).resumeInBackground('pty-1');
    final asked = server.sessionWork.asked.length;

    final again = await container
        .read(explorerActionsProvider)
        .resumeInBackground('pty-1');

    expect(again.outcome, ExplorerOutcome.reattached);
    expect(server.sessionWork.asked.length, asked);
  });

  test('stopped, then resumed before anything looked: it is held by the '
      'server again, so the peek offers Stop rather than Resume', () async {
    // Seen in the probe, 2026-10-07: Stop, then Resume from the dashboard,
    // and the running session still read as stopped.
    endedChat();
    final container = await connect();
    final actions = container.read(explorerActionsProvider);
    final launcher = container.read(sessionLauncherProvider);
    await actions.resumeInBackground('acp-1');
    expect(launcher.heldByHostOnly('acp-1'), isTrue);

    expect(await launcher.endRunning('acp-1'), isNotNull);
    expect(server.sessionWork.running, isNot(contains('acp-1')));
    await actions.resumeInBackground('acp-1');

    expect(server.sessionWork.running, contains('acp-1'));
    expect(launcher.heldByHostOnly('acp-1'), isTrue);
  });
}
