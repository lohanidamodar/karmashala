import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../probe/probe_mode.dart';

/// Where the app keeps everything per-user. `KARMASHALA_DATA_DIR` overrides
/// it — redirecting `%APPDATA%` does not, so such an instance shares the real one.
/// A probe without its own folder throws [ProbeDataDirectoryError].
Future<Directory> appSupportDirectory() => resolveDataDirectory(
  probe: ProbeMode.current,
  platformDefault: getApplicationSupportDirectory,
);
