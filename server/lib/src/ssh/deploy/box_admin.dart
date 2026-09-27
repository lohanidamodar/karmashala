import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host_protocol/protocol.dart' show SessionSummary;
import 'package:karmashala_ssh/connection.dart' show describeSshFailure;
import 'package:karmashala_ssh_host/host.dart';

import '../boxes/server_remote_hosts.dart';

/// **The explicit verbs on a box's host**, done by the server (slice 5d) for
/// a client's `ssh.deploy`, `ssh.hostSessions`, `ssh.endHostSession`,
/// `ssh.relaySetup`, `ssh.companionEndpoint` and `ssh.pairPhone`: install,
/// update, start, stop and remove the Karmashala host there; the relay a
/// desktop serves through; the port a phone dials and a pairing window. Over
/// the server's own connection and bundles — a client only asks.
class BoxAdmin {
  BoxAdmin(this._boxes);

  final ServerRemoteHosts _boxes;

  /// [action] on [hostId]'s host; the reading after it.
  Future<HostInstallReading> deploy(
    String hostId,
    SshDeployAction action,
  ) async {
    final access = _boxes.accessOf(hostId);
    final installer = HostInstaller(
      host: access.host,
      deployer: access.deployer(),
    );
    final reading = await _words(() async {
      return switch (action) {
        SshDeployAction.check => await installer.check(),
        SshDeployAction.install => await installer.install(),
        SshDeployAction.reinstall => await installer.install(reinstall: true),
        SshDeployAction.start => await installer.start(),
        SshDeployAction.stop => await installer.stop(),
        SshDeployAction.remove => await installer.remove(),
      };
    });
    if (action != SshDeployAction.check) {
      // The machine was changed on purpose: every shared reading is stale,
      // and a link to a host that was stopped or replaced is gone.
      _boxes.forgetReading(hostId);
      if (action != SshDeployAction.install) await _boxes.disconnect(hostId);
    }
    return reading;
  }

  /// Every session [hostId]'s host holds.
  Future<List<SessionSummary>> sessions(String hostId) =>
      _words(() => _boxes.boxSessions(hostId));

  /// Ends [sessionId] on [hostId] for good.
  Future<void> endSession(String hostId, String sessionId) =>
      _words(() => _boxes.closeOn(hostId, sessionId));

  /// [action] on the relay on [hostId], from the host bundle deployed there.
  Future<SshBoxAnswer<SshRelayReading>> relay(
    String hostId,
    SshRelayAction action, {
    required int port,
    bool ruleAddedByHand = false,
  }) async {
    final deployed = await _deployed(hostId);
    if (deployed.path == null) {
      return SshBoxAnswer.notDeployed(deployed.deployment);
    }
    final access = _boxes.accessOf(hostId);
    final setup = SshRelaySetup(
      host: access.host,
      target: access.target,
      remotePath: deployed.path!,
      port: port,
    );
    return SshBoxAnswer.of(
      await _words(
        () => switch (action) {
          SshRelayAction.check => setup.check(),
          SshRelayAction.start => setup.start(ruleAddedByHand: ruleAddedByHand),
          SshRelayAction.stop => setup.stop(),
          SshRelayAction.remove => setup.remove(),
        },
      ),
    );
  }

  /// Where a phone reaches [hostId]: its companion port, opened only against
  /// evidence it is shut and proved with a dial from the server.
  Future<SshBoxAnswer<CompanionEndpoint>> companionEndpoint(
    String hostId, {
    bool ruleAddedByHand = false,
  }) async {
    final setup = await _companion(hostId);
    if (setup.setup == null) {
      return SshBoxAnswer.notDeployed(setup.deployment);
    }
    return SshBoxAnswer.of(
      await _words(
        () => setup.setup!.prepare(ruleAddedByHand: ruleAddedByHand),
      ),
    );
  }

  /// A pairing window on [hostId]'s host.
  Future<SshBoxAnswer<PairingWindow>> pair(
    String hostId, {
    required int capabilities,
    String relay = '',
  }) async {
    final setup = await _companion(hostId);
    if (setup.setup == null) {
      return SshBoxAnswer.notDeployed(setup.deployment);
    }
    return SshBoxAnswer.of(
      await _words(
        () => setup.setup!.openWindow(capabilities: capabilities, relay: relay),
      ),
    );
  }

  Future<({SshCompanionSetup? setup, HostDeployment deployment})> _companion(
    String hostId,
  ) async {
    final deployed = await _deployed(hostId);
    final path = deployed.path;
    if (path == null || !deployed.deployment.isReady) {
      return (setup: null, deployment: deployed.deployment);
    }
    final access = _boxes.accessOf(hostId);
    return (
      setup: SshCompanionSetup(
        host: access.host,
        target: access.target,
        remotePath: path,
      ),
      deployment: deployed.deployment,
    );
  }

  /// The executable the box's host runs from — the one a pane runs, so a
  /// relay or a pairing lands on the host the sessions are in.
  Future<({String? path, HostDeployment deployment})> _deployed(
    String hostId,
  ) async {
    final deployment = await _words(() => _boxes.deployment(hostId));
    return (path: deployment.remotePath, deployment: deployment);
  }

  /// [work], with anything thrown turned into a refusal in words.
  static Future<T> _words<T>(Future<T> Function() work) async {
    try {
      return await work();
    } on DataRefused {
      rethrow;
    } on BoxUnavailable catch (error) {
      throw DataRefused(DataRefusalCode.failed, error.message);
    } on BoxLinkException catch (error) {
      throw DataRefused(DataRefusalCode.failed, error.message);
    } on Object catch (error) {
      throw DataRefused(DataRefusalCode.failed, describeSshFailure(error));
    }
  }
}
