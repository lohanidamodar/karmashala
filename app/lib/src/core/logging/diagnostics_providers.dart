import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../capabilities/capabilities.dart';
import '../paths/server_data_directory.dart';
import 'diagnostics_bootstrap.dart';

/// The app's log sinks. A provider over the process-wide instance so a test can
/// hand the UI its own without touching a global.
final diagnosticsProvider = Provider<Diagnostics>(
  (ref) => Diagnostics.instance,
);

/// Where the log files live, for the reveal button and the folder line.
final logDirectoryProvider = FutureProvider<Directory>(
  (ref) => defaultLogDirectory(),
);

/// This machine's server data folder.
final localServerDataDirectoryProvider = FutureProvider<Directory>(
  (ref) => serverDataDirectory(),
);

/// This machine's server log, `<data>/logs/server.log`, or null on a client
/// that hosts no server — whichever server the window is a client of.
final serverLogFileProvider = FutureProvider<File?>((ref) async {
  if (!ref.watch(clientCapabilitiesProvider).hostsServer) return null;
  final data = await ref.watch(localServerDataDirectoryProvider.future);
  return File(p.join(data.path, 'logs', 'server.log'));
});
