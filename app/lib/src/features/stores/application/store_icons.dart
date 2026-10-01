import 'dart:io';
import 'dart:typed_data';

import 'package:agent_cli/process.dart'
    show EnvironmentPath, localHostEnvironmentId;
import 'package:riverpod/riverpod.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../media/application/session_media_providers.dart'
    show serverMediaFilesProvider;

/// Which kept icon to show: the server's copy, and when the server last
/// looked it up — a new lookup may have rewritten the same file.
typedef StoreIconKey = ({String path, DateTime checkedAt});

/// An app's icon as bytes, or null when it cannot be had: opened as it is
/// when this machine is the server's, else brought over `files.read` like a
/// session's pictures (`ServerMediaFiles`). Never throws; a missing icon
/// draws the placeholder.
final storeIconBytesProvider = FutureProvider.autoDispose
    .family<Uint8List?, StoreIconKey>((ref, key) async {
      try {
        final File file;
        if (ref.watch(capabilitiesProvider.select((c) => c.readsServerDisk))) {
          file = File(key.path);
        } else {
          file = await ref
              .watch(serverMediaFilesProvider)
              .fetch(
                EnvironmentPath(
                  environmentId: localHostEnvironmentId,
                  path: key.path,
                ),
              );
        }
        final bytes = await file.readAsBytes();
        return bytes.isEmpty ? null : bytes;
      } on Object {
        // MediaUnavailable, a dropped link, a file gone: the placeholder.
        return null;
      }
    });
