import 'dart:async';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_host/data.dart' show HostDataLink;
import 'package:karmashala_ssh_host/host.dart' show HostDeploymentStatus;
import 'package:karmashala_terminal_runtime/host_link.dart'
    show LocalHostSessionAccess, LocalHostSupervisor;

import 'data_client.dart';

/// Connects this app's data to this machine's server before the first frame,
/// starting (or adopting) it through [access] — the one the container is
/// given, so the supervisor shares the start. Always started, whatever the
/// terminal settings: notes, todos and settings live at the server.
///
/// A server that does not come up is said, not replaced: the client comes
/// back unavailable with the reason, keeps redialling, and everything is
/// read again when the server answers.
Future<DataClient> connectLocalServerData({
  required LocalHostSessionAccess? access,
  AppLogger? logger,
}) async {
  final log = logger ?? AppLogger.named('data');
  if (access == null) {
    const reason = 'no Karmashala server may run here';
    log.warning('Data: $reason.');
    return DataClient.unavailable(reason, logger: log);
  }
  String? notUp;
  try {
    final reading = await access.deployment();
    if (reading.status != HostDeploymentStatus.ready) {
      notUp = '${reading.status.name}: ${reading.reason}';
    }
  } on Object catch (error) {
    notUp = 'it did not start ($error)';
  }
  final client = await DataClient.connect(
    () => HostDataLink.connect(access.socketPath),
    unavailableReason: notUp,
    logger: log,
  );
  if (client.connection.state == DataLinkState.connected) {
    log.info('Data: through the Karmashala server (${access.socketPath}).');
  } else {
    log.warning(
      'Data: the Karmashala server is not reachable '
      '(${client.connection.reason}). Notes, todos and settings wait for it.',
    );
  }
  return client;
}

/// Ties the data link to the supervisor that keeps this machine's server
/// up: a server it brings back is dialled at once, a data link that closes is
/// reported to it as a possible loss (it checks before acting), and each
/// redial that finds nobody nudges it — a supervisor stopped for want of a
/// binary looks again then, no more often than its own floor allows.
/// Returns what undoes it.
void Function() superviseDataLink(
  DataClient client,
  LocalHostSupervisor supervisor,
) {
  final restarted = supervisor.restarted.listen((_) => client.retry());
  var wasConnected = client.connection.state == DataLinkState.connected;
  final changes = client.connectionChanges.listen((connection) {
    final connected = connection.state == DataLinkState.connected;
    if (wasConnected && !connected) {
      supervisor.hostLost('the data link to it closed');
    }
    if (connection.state == DataLinkState.unavailable) {
      supervisor.nudge('the data client found no server');
    }
    wasConnected = connected;
  });
  return () {
    unawaited(restarted.cancel());
    unawaited(changes.cancel());
  };
}
