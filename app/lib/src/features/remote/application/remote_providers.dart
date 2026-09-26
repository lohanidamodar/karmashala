import 'dart:io';

import 'package:riverpod/riverpod.dart';

import 'package:karmashala_companion_server/karmashala_companion_server.dart';

export '../data/paired_devices_data.dart'
    show pairedDevicesDataProvider, pairedDevicesProvider;

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
