import 'package:riverpod/riverpod.dart';

import '../../agents/application/host_hook_endpoint.dart';
import 'host_companion_link.dart';
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
final hostCompanionLinkProvider = Provider<HostCompanionLink>(
  (ref) => HostCompanionLink(
    bindings: () => ref.read(remoteHostBindingsProvider),
    deviceById: (deviceId) =>
        ref.read(pairedDeviceDaoProvider).getById(deviceId),
    onDevicesChanged: () =>
        ref.read(pairedDevicesRevisionProvider.notifier).bump(),
  ),
);
