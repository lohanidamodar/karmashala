import 'dart:async';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_host/lifecycle_client.dart' show ServerMethod;
import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_installations_controller.dart';
import '../../agents/application/host_hook_endpoint.dart';
import 'host_companion_link.dart';
import 'remote_access_controller.dart';
import 'remote_bindings.dart';
import 'remote_providers.dart';

/// Whether this machine's session host serves the phone companion: whenever
/// local panes are host-backed, as it serves agents' hooks and tools. This app
/// then runs no companion server of its own — one machine, one server.
final companionAtHostProvider = Provider<bool>(
  (ref) => ref.watch(agentHooksAtHostProvider),
);

/// This app's half of the companion the host serves: it answers the calls the
/// host forwards with the same bindings this app's own server would use.
final hostCompanionLinkProvider = Provider<HostCompanionLink>((ref) {
  late final HostCompanionLink link;
  link = HostCompanionLink(
    bindings: () => ref.read(remoteHostBindingsProvider),
    deviceById: (deviceId) =>
        ref.read(pairedDeviceDaoProvider).getById(deviceId),
    onDevicesChanged: () =>
        ref.read(pairedDevicesRevisionProvider.notifier).bump(),
    // Maybe a new host: what it serves by is read again, and the agent CLIs
    // it found on this machine are what the app lists.
    onAttached: () {
      unawaited(ref.read(remoteAccessControllerProvider).reload());
      unawaited(_refreshAgents(ref, link));
    },
  );
  return link;
});

final _log = AppLogger.named('remote.host');

/// Asks the server to look for this machine's agent CLIs (`agents.refresh`,
/// sharing the probe its start is already running) and re-reads the rows it
/// wrote. The app's own sweep still reconciles every environment.
Future<void> _refreshAgents(Ref ref, HostCompanionLink link) async {
  try {
    final answer = await link.serverCall(ServerMethod.agentsRefresh);
    _log.info('Agent CLIs on this machine: ${answer['summary']}');
    ref.read(agentInstallationsControllerProvider.notifier).reload();
  } on Object catch (error) {
    _log.info('The server did not refresh its agent CLIs: $error');
  }
}
