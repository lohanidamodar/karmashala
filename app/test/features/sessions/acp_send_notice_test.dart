import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_notice.dart';
import 'package:karmashala_session/session.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// What the server says of a send — an image the agent was given as its path
/// rather than as an image — is shown on the session's own notice bar.
void main() {
  late TestMachine db;
  late FakeDataServer server;

  setUp(() {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(id: 'acp', agentId: AgentIds.claudeAcp),
    );
    server.sessionWork.typesSends = true;
    db.server.sessionRows.insert(
      session(
        id: 'acp-1',
        agentInstallationId: 'acp',
        status: SessionStatus.running,
      ),
    );
    server.sessionWork.running.add('acp-1');
  });

  Future<ProviderContainer> connect() async {
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        ...fakeTerminalOverrides(machine: db),
        serverOfferProvider.overrideWithValue(
          const ServerOffer(
            sameMachine: true,
            serverOs: 'windows',
            features: {'sessions.send', 'sessions.interrupt'},
          ),
        ),
        sessionRunningOnHostProvider.overrideWithValue((_) => true),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test("the server's notice of a send is posted for that session", () async {
    server.sessionWork.sendNotice =
        'Fake agent does not take images in a prompt, so the image was sent '
        'as its path.';
    final container = await connect();

    await container
        .read(sessionActionsProvider)
        .continueSession('acp-1', 'look\n\nAttached image(s):\nC:\\a.png');

    expect(
      container.read(sessionNoticesProvider)['acp-1']?.message,
      server.sessionWork.sendNotice,
    );
  });

  test('a send with nothing to say posts nothing', () async {
    final container = await connect();
    await container
        .read(sessionActionsProvider)
        .continueSession('acp-1', 'hello');
    expect(container.read(sessionNoticesProvider), isEmpty);
  });
}
