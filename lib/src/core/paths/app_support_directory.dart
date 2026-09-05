import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Where the app keeps everything per-user: the database, logs, the IPC
/// socket, the env vault.
///
/// Normally the OS application-support directory. `KARMASHALA_DATA_DIR`
/// overrides it, which is the only way to start against an empty database —
/// `path_provider` resolves Windows' folder through `SHGetKnownFolderPath`, so
/// redirecting `%APPDATA%` does nothing and an instance launched that way
/// silently shares the real one.
///
/// For screenshots, demos and running a build against throwaway data. Not a
/// user setting: nothing in the app writes it.
Future<Directory> appSupportDirectory() async {
  final override = Platform.environment['KARMASHALA_DATA_DIR'];
  if (override != null && override.trim().isNotEmpty) {
    final dir = Directory(override.trim());
    await dir.create(recursive: true);
    return dir;
  }
  return getApplicationSupportDirectory();
}
