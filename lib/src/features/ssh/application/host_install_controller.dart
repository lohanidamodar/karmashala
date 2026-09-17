/// The session host on one SSH machine, looked at and acted on **on purpose**:
/// the explicit half of what a pane, a relay and a pairing do implicitly.
library;

import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_ssh/host.dart';
import 'package:riverpod/riverpod.dart';

import '../../remote/application/ssh_relay_controller.dart';
import '../../remote/application/ssh_relays.dart';
import 'host_session_providers.dart';
import 'ssh_failure.dart';
import 'ssh_providers.dart';

/// Builds the installer for one box, over the app's pooled connection and the
/// bundles this build carries. A seam, so a test drives a fake machine.
typedef HostInstallerFactory = HostInstaller Function(SshHost host);

final hostInstallerFactoryProvider = Provider<HostInstallerFactory>(
  (ref) =>
      (host) => HostInstaller(
        host: host,
        deployer: HostDeployer(
          target: SshHostDeployTarget(
            ref.read(sshConnectionPoolProvider).forHostId(host.id),
          ),
          binaries: ref.read(hostBinarySourceProvider),
        ),
      ),
);

/// What a row is doing, in the words its spinner shows.
enum HostInstallAction {
  check('Asking the machine…'),
  install('Installing the session host…'),
  reinstall('Installing the session host again…'),
  start('Starting the session host…'),
  stop('Stopping the session host…'),
  remove('Removing the session host…');

  const HostInstallAction(this.progress);
  final String progress;
}

/// What is known about one machine's host since this launch: a reading with
/// its time, never re-taken on its own (§19).
class HostInstallView {
  const HostInstallView({this.reading, this.busy, this.failure});

  final HostInstallReading? reading;

  /// The action in flight, or null.
  final HostInstallAction? busy;

  /// Why the machine could not even be asked, already worded for a person.
  final String? failure;
}

class HostInstallController extends Notifier<Map<String, HostInstallView>> {
  @override
  Map<String, HostInstallView> build() => const {};

  Future<HostInstallReading?> check(SshHost host) =>
      _run(host, HostInstallAction.check, (it) => it.check());

  /// Install and Update: the one deploy.
  Future<HostInstallReading?> install(SshHost host) =>
      _run(host, HostInstallAction.install, (it) => it.install());

  Future<HostInstallReading?> reinstall(SshHost host) => _run(
    host,
    HostInstallAction.reinstall,
    (it) => it.install(reinstall: true),
  );

  Future<HostInstallReading?> start(SshHost host) =>
      _run(host, HostInstallAction.start, (it) => it.start());

  Future<HostInstallReading?> stop(SshHost host) =>
      _run(host, HostInstallAction.stop, (it) => it.stop());

  /// Stops host and relay there and deletes what they wrote; the relay's row
  /// here goes with it, since its address no longer exists.
  Future<HostInstallReading?> remove(SshHost host) async {
    final reading = await _run(
      host,
      HostInstallAction.remove,
      (it) => it.remove(),
    );
    if (reading?.state == HostInstallState.notInstalled &&
        ref.read(sshRelaysProvider.notifier).entryFor(host.id) != null) {
      ref.read(sshRelayControllerProvider.notifier).forget(host.id);
    }
    return reading;
  }

  Future<HostInstallReading?> _run(
    SshHost host,
    HostInstallAction action,
    Future<HostInstallReading> Function(HostInstaller installer) act,
  ) async {
    final before = state[host.id]?.reading;
    _set(host.id, HostInstallView(reading: before, busy: action));
    try {
      final reading = await act(ref.read(hostInstallerFactoryProvider)(host));
      if (!ref.mounted) return reading;
      if (action != HostInstallAction.check) _forgetSharedReadings(host);
      _set(host.id, HostInstallView(reading: reading));
      return reading;
    } on Object catch (error) {
      if (!ref.mounted) return null;
      _set(
        host.id,
        HostInstallView(reading: before, failure: describeSshFailure(error)),
      );
      return null;
    }
  }

  /// A pane, a relay and a pairing share one memoised deploy reading per
  /// connection; after the machine was changed on purpose it is stale.
  void _forgetSharedReadings(SshHost host) {
    ref.read(hostSessionAccessRegistryProvider).forgetReading(host.id);
    ref.invalidate(sshCompanionSetupProvider(host));
  }

  void _set(String hostId, HostInstallView view) =>
      state = {...state, hostId: view};
}

final hostInstallControllerProvider =
    NotifierProvider<HostInstallController, Map<String, HostInstallView>>(
      HostInstallController.new,
    );
