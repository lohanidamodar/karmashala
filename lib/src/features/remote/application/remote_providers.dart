import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/database_providers.dart';
import '../data/paired_device_dao.dart';
import '../domain/paired_device.dart';
import '../protocol.dart';

/// Data access for the paired-device store.
final pairedDeviceDaoProvider = Provider<PairedDeviceDao>(
  (ref) => PairedDeviceDao(ref.watch(databaseProvider)),
);

/// Bumped after pairing, revocation or a last-seen update, so lists re-read.
class PairedDevicesRevisionController extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final pairedDevicesRevisionProvider =
    NotifierProvider<PairedDevicesRevisionController, int>(
      PairedDevicesRevisionController.new,
    );

/// Every paired device, newest first — what the settings list shows.
final pairedDevicesProvider = Provider.autoDispose<List<PairedDevice>>((ref) {
  ref.watch(pairedDevicesRevisionProvider);
  return ref.watch(pairedDeviceDaoProvider).getAll();
});

/// Metadata key holding this host's own [DeviceId].
const String kHostDeviceIdMetadataKey = 'remote.host_device_id';

/// This host's stable identity for the remote key schedule: minted once,
/// persisted in `app_metadata`, and bound into every device key.
DeviceId hostDeviceIdFor(AppDatabase db) {
  final existing = db.readMetadata(kHostDeviceIdMetadataKey);
  if (existing != null) {
    try {
      return DeviceId.parse(existing);
    } on ProtocolException {
      // Unreadable — mint a fresh one below. Existing pairings are lost, but
      // a corrupt id could never have matched them anyway.
    }
  }
  final id = DeviceId.generate();
  db.writeMetadata(kHostDeviceIdMetadataKey, id.value);
  return id;
}

final hostDeviceIdProvider = Provider<DeviceId>(
  (ref) => hostDeviceIdFor(ref.watch(databaseProvider)),
);
