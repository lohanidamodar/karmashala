import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Where the app keeps everything per-user. `KARMASHALA_DATA_DIR` overrides
/// it — redirecting `%APPDATA%` does not, so such an instance shares the real one.
Future<Directory> appSupportDirectory() async {
  final override = Platform.environment['KARMASHALA_DATA_DIR'];
  if (override != null && override.trim().isNotEmpty) {
    final dir = Directory(override.trim());
    await dir.create(recursive: true);
    return dir;
  }
  return getApplicationSupportDirectory();
}
