import 'dart:io';

import 'package:riverpod/riverpod.dart';

import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import '../../../core/database/database_providers.dart';
import 'package:karmashala_store/devices.dart';
import 'package:karmashala_remote/remote.dart';

// One identity whichever of this app and the session host serves the phones.
export 'package:karmashala_companion_server/karmashala_companion_server.dart'
    show hostDeviceIdFor, kHostDeviceIdMetadataKey;

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
