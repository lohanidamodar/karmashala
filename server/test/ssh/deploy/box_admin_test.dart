import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host_protocol/host_access.dart';
import 'package:test/test.dart';

import '../support/box_world.dart';

/// The explicit verbs on a box's host, asked by a client through the data
/// API and done by the server over its own connection and bundles (slice
/// 5d): look, install, the host's sessions, ending one, a relay on a box
/// that cannot run the host, and a pairing window.
void main() {
  late BoxWorld world;

  setUp(() => world = BoxWorld());
  tearDown(() => world.close());

  test('ssh.deploy: a look changes nothing; install puts the server\'s '
      'bundle there and it answers', () async {
    final looked = await world.ask(
      const SshDeploy(BoxWorld.hostId, SshDeployAction.check),
    );
    expect(looked.state, HostInstallState.notInstalled);
    expect(looked.offeredVersion, '1.25.0');
    expect(world.box.uploads, isEmpty);

    final installed = await world.ask(
      const SshDeploy(BoxWorld.hostId, SshDeployAction.install),
    );
    expect(installed.state, HostInstallState.installed);
    expect(world.box.uploads, hasLength(1));
  });

  test('ssh.hostSessions lists what the box holds; ssh.endHostSession ends '
      'one there', () async {
    await world.ssh.remote.open(
      world.environment,
      sessionId: 'karmashala_local_p1',
      columns: 80,
      rows: 24,
    );
    final listed = await world.ask(const SshHostSessions(BoxWorld.hostId));
    expect(listed.single.id, 'karmashala_local_p1');
    expect(listed.single.lifecycle.hasEnded, isFalse);

    final pty = world.box.ptys.single;
    Future<void>.delayed(
      const Duration(milliseconds: 20),
      () => pty.finish(143),
    );
    await world.ask(
      const SshEndHostSession(BoxWorld.hostId, 'karmashala_local_p1'),
    );
    expect(pty.signals, contains(15));
  });

  test('ssh.relaySetup on a box that cannot run the host answers the deploy '
      'that did not end ready, for its remedy and button', () async {
    world.box.uname = 'Linux\naarch64\nldd (GNU libc) 2.39\n';
    final answer = await world.ask(
      const SshBoxRelay(BoxWorld.hostId, SshRelayAction.start),
    );
    expect(answer.value, isNull);
    final deployment = answer.deployment!;
    expect(deployment.status, HostDeploymentStatus.noBinary);
    expect(deployment.reason, contains('linux-arm64'));
    final said = explainHostDeployment(deployment, hostName: 'do-box');
    expect(said.action, HostDeployAction.retry);
  });

  test('ssh.pairPhone asks the box\'s own host: one with no store says it '
      'cannot pair, in its words', () async {
    final answer = await world.ask(
      const SshPairPhone(BoxWorld.hostId, capabilities: 7),
    );
    final window = answer.value!;
    expect(window.status, PairingRequestStatus.hostCannotPair);
    expect(window.reason, contains('cannot pair'));
  });

  test('a host nobody saved is refused, not guessed at', () async {
    await expectLater(
      world.ask(const SshHostSessions('nobody')),
      throwsA(
        isA<DataRefused>().having(
          (e) => e.code,
          'code',
          DataRefusalCode.notFound,
        ),
      ),
    );
  });
}
