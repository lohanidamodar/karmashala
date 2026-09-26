import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'package:karmashala_core/logging.dart';
import '../paths/app_support_directory.dart';

/// Where log files live: `<app support>/logs` — the same per-user location as
/// the database, the IPC socket and the MCP handshake.
Future<Directory> defaultLogDirectory() async =>
    Directory(p.join((await appSupportDirectory()).path, 'logs'));

/// Opens the rotating log file and attaches it to [diagnostics]. Best-effort:
/// a disk that refuses leaves the in-memory sinks running, not a failed launch.
Future<LogFileSink?> attachDefaultLogFile(
  Diagnostics diagnostics, {
  bool enabled = true,
}) async {
  if (!enabled) return null;
  final existing = diagnostics.file;
  if (existing != null) return existing;
  try {
    final sink = LogFileSink(directory: await defaultLogDirectory());
    diagnostics.attachFile(sink);
    return sink;
  } catch (_) {
    return null;
  }
}

/// Applies the user's diagnostics preferences to the live sinks, synchronously
/// except the file. Debug mode moves `Logger.root.level`, or nothing is logged.
void applyDiagnosticsSettings(
  Diagnostics diagnostics, {
  required bool debugMode,
  required Level fileLevel,
  required bool logToFile,
  required int bufferSize,
}) {
  Logger.root.level = debugMode ? Level.ALL : Level.INFO;
  diagnostics.buffer.resize(bufferSize);
  final file = diagnostics.file;
  if (!logToFile) {
    if (file != null) unawaited(diagnostics.detachFile());
    return;
  }
  if (file == null) {
    unawaited(attachDefaultLogFile(diagnostics));
  } else {
    file.minimumLevel = fileLevel;
  }
}
