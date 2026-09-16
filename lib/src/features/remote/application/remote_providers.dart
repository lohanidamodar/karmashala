import 'dart:io';

import 'package:riverpod/riverpod.dart';

import 'package:karmashala_store/database.dart';
import '../../../core/database/database_providers.dart';
import '../data/companion_attachment_store.dart';
import '../data/paired_device_dao.dart';
import 'package:karmashala_remote/remote.dart';

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

/// Where a file the phone sends lands: `<temp>/karmashala/attachments`,
/// resolved rather than stored because a stored absolute path rots (§20).
final companionAttachmentStoreProvider =
    FutureProvider<CompanionAttachmentStore>((ref) async {
      final store = CompanionAttachmentStore(
        Directory('${Directory.systemTemp.path}/karmashala/attachments'),
      );
      // The one moment there is provably nothing in flight: no link has been
      // made yet. Once, on demand — nothing polls.
      await store.sweep();
      return store;
    });
