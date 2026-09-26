import 'dart:async';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_host/data.dart' show HostDataLink;
import 'package:karmashala_ssh/host.dart' show HostDeploymentStatus;
import 'package:karmashala_store/database.dart';
import 'package:karmashala_terminal_runtime/host_link.dart'
    show LocalHostSessionAccess;

import '../../features/settings/data/settings_repository.dart';
import 'app_preferences.dart';
import 'data_client.dart';

/// Connects this app's data to this machine's server, before the first frame
/// — the server is started here when local panes are host-backed, as the
/// launch would start it anyway, so it is the same one start ([access] is
/// the one the container is given).
///
/// Where no server can be reached, the answer is the **temporary**
/// in-process fallback over [database], said loudly in the log and in
/// Settings: the app keeps working rather than refusing to open.
Future<DataClient> connectLocalServerData({
  required AppDatabase database,
  required LocalHostSessionAccess? access,
  AppLogger? logger,
}) async {
  final log = logger ?? AppLogger.named('data');
  String reason;
  if (access == null) {
    reason = 'no Karmashala server may run here';
  } else {
    final starts = _hostBackedLocalPanes(database);
    try {
      final reading = starts
          ? await access.deployment()
          : await access.observe();
      if (reading.status == HostDeploymentStatus.ready) {
        final client = await DataClient.connect(
          () => HostDataLink.connect(access.socketPath),
          logger: log,
        );
        log.info('Data: through the Karmashala server (${access.socketPath}).');
        return client;
      }
      reason = starts
          ? 'the Karmashala server is not up (${reading.status.name}: '
                '${reading.reason})'
          : 'no Karmashala server is running, and none is started while '
                'local panes are not host-backed';
    } on Object catch (error) {
      reason = 'the Karmashala server did not answer ($error)';
    }
  }
  log.warning(
    'Data: $reason. TEMPORARY fallback: notes, todos and preferences are '
    'read and written in this process, straight to the database.',
  );
  return DataClient.inProcess(database, reason: reason, logger: log);
}

/// **Temporary**: the one setting needed before any server is reached —
/// whether to start one — read through the fallback, since the server that
/// would answer it may be the one it decides to start.
bool _hostBackedLocalPanes(AppDatabase database) {
  final peek = DataClient.inProcess(database, reason: 'reading one setting');
  try {
    return SettingsRepository(AppPreferences(peek)).load().hostBackedLocalPanes;
  } finally {
    unawaited(peek.close());
  }
}
