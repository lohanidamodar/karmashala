import 'dart:async';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_host/lifecycle_client.dart' show ServerMethod;
import 'package:riverpod/riverpod.dart';

import '../../terminal/application/local_host_providers.dart';
import 'host_companion_link.dart';
import 'remote_access_controller.dart';
import 'remote_providers.dart';

/// Whether this app has a link to this machine's server's companion: whenever
/// a local server may be reached, whatever the panes setting. The app never
/// runs a companion server of its own.
final companionAtHostProvider = Provider<bool>(
  (ref) => ref.watch(localHostSessionAccessProvider) != null,
);

/// This app's half of the companion the server serves: pairing and the
/// server's config. Every phone call is the server's, and so is its LAN relay.
final hostCompanionLinkProvider = Provider<HostCompanionLink>((ref) {
  late final HostCompanionLink link;
  link = HostCompanionLink(
    deviceById: (deviceId) =>
        ref.read(pairedDevicesDataProvider).fresh(deviceId),
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
/// sharing the probe its start is already running); the rows it writes reach
/// the app's copy as changes. The app's own sweep still reconciles every
/// environment.
Future<void> _refreshAgents(Ref ref, HostCompanionLink link) async {
  try {
    final answer = await link.serverCall(ServerMethod.agentsRefresh);
    _log.info('Agent CLIs on this machine: ${answer['summary']}');
  } on Object catch (error) {
    _log.info('The server did not refresh its agent CLIs: $error');
  }
}
