import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_actions.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_core/geometry.dart' show chatPaneId;

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// **Sending to an ended ACP session resumes it first** — at the server,
/// through `sessions.resume`, the way a session with no pane of ours comes
/// back — and the message is then its next turn over `sessions.send`. The
/// server owns the agent: nothing is typed into a pane here and nothing is
/// started by this app's own engine. One the server still runs is sent to
/// as it is.
void main() {
  late TestMachine db;
  late FakeDataServer server;

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(
        id: 'acp',
        agentId: AgentIds.claudeAcp,
        path: r'C:\Users\me\.bin\claude-agent-acp.exe',
      ),
    );
    server.installationRows.insert(agentInstallation(id: 'pty'));
    server.sessionWork.typesSends = true;
  });

  Future<ProviderContainer> connect({
    bool runningOnHost = false,
    bool serverResumes = false,
  }) async {
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        ...fakeTerminalOverrides(machine: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        // A server that types sends itself (Stage 2 step 2) — and, newer,
        // resumes an ACP session a send reaches.
        serverOfferProvider.overrideWithValue(
          ServerOffer(
            sameMachine: true,
            serverOs: 'windows',
            features: {
              'sessions.send',
              'sessions.interrupt',
              if (serverResumes) 'sessions.send.resumes',
            },
          ),
        ),
        sessionRunningOnHostProvider.overrideWithValue((_) => runningOnHost),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  List<SessionResume> resumesAsked() => [
    for (final request in server.sessionWork.asked)
      if (request is SessionResume) request,
  ];

  test('an ended ACP session is resumed at the server, then sent to, and '
      'its chat tab is shown', () async {
    db.server.sessionRows.insert(
      session(
        id: 'acp-1',
        agentInstallationId: 'acp',
        status: SessionStatus.completed,
      ),
    );
    final container = await connect();

    await container
        .read(sessionActionsProvider)
        .continueSession('acp-1', 'carry on');

    expect(resumesAsked().map((r) => r.sessionId), ['acp-1']);
    expect(resumesAsked().single.restart, isFalse);
    // Sent only once the server ran it again: the resume came first.
    expect(server.sessionWork.sent.single.text, 'carry on');
    expect(server.sessionWork.running, {'acp-1'});
    expect(
      db.server.sessionRows.getById('acp-1')!.status,
      SessionStatus.running,
    );
    final tabs = container.read(terminalSessionsControllerProvider).tabs;
    expect(tabs.single.layout.panes, [chatPaneId('acp-1')]);
  });

  test('an ACP session the server runs is sent to as it is', () async {
    db.server.sessionRows.insert(
      session(
        id: 'acp-1',
        agentInstallationId: 'acp',
        status: SessionStatus.running,
      ),
    );
    server.sessionWork.running.add('acp-1');
    final container = await connect(runningOnHost: true);

    await container
        .read(sessionActionsProvider)
        .continueSession('acp-1', 'and then');

    expect(resumesAsked(), isEmpty);
    expect(server.sessionWork.sent.single.text, 'and then');
  });

  test('a row that says running but the server does not run is resumed '
      'anyway: the row is a claim, the server is the fact', () async {
    db.server.sessionRows.insert(
      session(
        id: 'acp-1',
        agentInstallationId: 'acp',
        status: SessionStatus.running,
      ),
    );
    final container = await connect();

    await container
        .read(sessionActionsProvider)
        .continueSession('acp-1', 'still there?');

    expect(resumesAsked().map((r) => r.sessionId), ['acp-1']);
    expect(server.sessionWork.sent.single.text, 'still there?');
  });

  test('a resume the server refuses is said in its words and nothing is '
      'sent', () async {
    db.server.sessionRows.insert(
      session(
        id: 'acp-1',
        agentInstallationId: 'acp',
        status: SessionStatus.completed,
      ),
    );
    server.sessionWork.refuseWith = 'That agent is not installed any more.';
    final container = await connect();

    await expectLater(
      container.read(sessionActionsProvider).continueSession('acp-1', 'hi'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'That agent is not installed any more.',
        ),
      ),
    );
    expect(server.sessionWork.sent, isEmpty);
  });

  test('a PTY session is untouched: typed into by the server, never '
      'resumed here', () async {
    db.server.sessionRows.insert(
      session(
        id: 'pty-1',
        agentInstallationId: 'pty',
        status: SessionStatus.running,
      ),
    );
    server.sessionWork.running.add('pty-1');
    final container = await connect(runningOnHost: true);

    await container
        .read(sessionActionsProvider)
        .continueSession('pty-1', 'carry on');

    expect(resumesAsked(), isEmpty);
    expect(server.sessionWork.sent.single.sessionId, 'pty-1');
  });

  test('a server that resumes on send is only sent to: it resumes the '
      'session in the same request, as for every client', () async {
    db.server.sessionRows.insert(
      session(
        id: 'acp-1',
        agentInstallationId: 'acp',
        status: SessionStatus.completed,
      ),
    );
    server.sessionWork.resumesOnSend = true;
    final container = await connect(serverResumes: true);

    await container
        .read(sessionActionsProvider)
        .continueSession('acp-1', 'carry on');

    expect(resumesAsked(), isEmpty);
    expect(server.sessionWork.sent.single.text, 'carry on');
    expect(server.sessionWork.running, {'acp-1'});
  });
}
