import 'package:agent_cli/descriptors.dart' show ResolvedPermission;
import 'package:agent_cli/stream.dart' show FakeChatProtocol;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_engine_provider.dart';
import 'package:karmashala/src/features/sessions/application/session_notice.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/launch.dart' show SessionSurface;
import 'package:karmashala_session/session.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// **A message to a terminal session nothing runs resumes it for real.** The
/// chat composer's send used to run it as a one-off headless turn, where an
/// agent's questions and approvals have nobody to ask. It now relaunches the
/// session's terminal at the server, as Resume does, with the message as its
/// first prompt — delivered the way the agent's descriptor declares.
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
        sessionRunningOnHostProvider.overrideWithValue((_) => false),
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

  test('an ended terminal session is relaunched in a pane with the message '
      'as its first prompt, never run headless', () async {
    db.server.sessionRows.insert(
      session(
        id: 'pty-1',
        agentInstallationId: 'pty',
        status: SessionStatus.completed,
      ).copyWith(externalSessionId: 'conv-1'),
    );
    final container = await connect();

    await container
        .read(sessionActionsProvider)
        .continueSession('pty-1', 'ask me which fruit i like');

    final spec = starts().single;
    expect(spec.resumeConversationId, 'conv-1');
    expect(spec.newSession, isFalse);
    expect(spec.prompt, 'ask me which fruit i like');
    expect(container.read(sessionEngineProvider).isActive('pty-1'), isFalse);
    // The same row came back, in a pane of this window.
    expect(server.sessionWork.running, {'pty-1'});
    final paneId = db.server.sessionRows.getById('pty-1')!.paneId;
    expect(paneId, isNotNull);
    final tabs = container.read(terminalSessionsControllerProvider).tabs;
    expect(tabs.expand((tab) => tab.layout.panes), contains(paneId));
    expect(container.read(sessionsStartingProvider), isEmpty);
  });

  test('a one-off turn this app still holds for it does not take the '
      'message: it ends, and the session comes back in a pane', () async {
    // The probe's log, 2026-10-05: "Continued … through the engine:
    // resumed=false" — an engine runtime left from an earlier headless turn
    // swallowed the message.
    final row = session(
      id: 'pty-1',
      agentInstallationId: 'pty',
      status: SessionStatus.completed,
    ).copyWith(externalSessionId: 'conv-1');
    db.server.sessionRows.insert(row);
    final container = await connect();
    final engine = container.read(sessionEngineProvider);
    await engine.resume(
      session: row,
      workingDirectory: repository().path,
      installation: agentInstallation(id: 'pty'),
      permission: ResolvedPermission.none,
    );
    expect(engine.isActive('pty-1'), isTrue);

    await container
        .read(sessionActionsProvider)
        .continueSession('pty-1', 'please ask that again');

    expect(starts().single.prompt, 'please ask that again');
    expect(engine.isActive('pty-1'), isFalse);
  });

  test('one that never named a conversation starts a fresh one in its own '
      'row, carrying the message', () async {
    db.server.sessionRows.insert(
      session(
        id: 'pty-1',
        agentInstallationId: 'pty',
        status: SessionStatus.failed,
      ),
    );
    final container = await connect();

    await container
        .read(sessionActionsProvider)
        .continueSession('pty-1', 'try again');

    final spec = starts().single;
    expect(spec.restartSessionId, 'pty-1');
    expect(spec.resumeConversationId, isNull);
    expect(spec.prompt, 'try again');
    expect(container.read(sessionEngineProvider).isActive('pty-1'), isFalse);
  });

  test('a session in an external terminal keeps its one-off turn, and says '
      'that questions cannot be asked there, offering Resume', () async {
    db.server.sessionRows.insert(
      session(
        id: 'ext-1',
        agentInstallationId: 'pty',
        status: SessionStatus.completed,
      ).copyWith(externalSessionId: 'conv-2', surface: SessionSurface.external),
    );
    final container = await connect();

    await container
        .read(sessionActionsProvider)
        .continueSession('ext-1', 'one more thing');

    expect(starts(), isEmpty);
    expect(container.read(sessionEngineProvider).isActive('ext-1'), isTrue);
    final notice = container.read(sessionNoticeProvider('ext-1'));
    expect(notice, isNotNull);
    expect(notice!.message, contains("can't be asked"));
    expect(notice.action?.label, 'Resume here');

    notice.action!.onPressed();
    await pumpEventQueue();
    final spec = starts().single;
    expect(spec.resumeConversationId, 'conv-2');
    expect(spec.prompt, isNull);
  });
}
