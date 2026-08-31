import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'diagnostics.dart';
import 'log_file_sink.dart';

/// Where log files live: `<app support>/logs`.
///
/// The app support directory rather than beside the database: it is the
/// per-user, per-app location the OS already backs up and cleans up, and it is
/// the same place the database, the IPC socket and the MCP handshake use. It is
/// not somewhere anyone would *find*, which is why Settings → Diagnostics has a
/// reveal button pointing at it.
Future<Directory> defaultLogDirectory() async =>
    Directory(p.join((await getApplicationSupportDirectory()).path, 'logs'));

/// Opens the rotating log file and attaches it to [diagnostics].
///
/// Best-effort by construction: a platform with no app support directory, or a
/// disk that refuses, leaves the in-memory sinks running rather than failing a
/// launch over a log file.
Future<LogFileSink?> attachDefaultLogFile(
  Diagnostics diagnostics, {
  bool enabled = true,
}) async {
  if (!enabled) return null;
  try {
    final sink = LogFileSink(directory: await defaultLogDirectory());
    diagnostics.attachFile(sink);
    return sink;
  } catch (_) {
    return null;
  }
}
