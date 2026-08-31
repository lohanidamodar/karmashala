import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
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

/// Applies the user's diagnostics preferences to the live sinks.
///
/// Synchronous on purpose. The two things that must take effect *now* — the
/// root level and the buffer bound — do; opening or closing the file is the
/// only part that touches a disk, and it is left running in the background so
/// flipping a switch never blocks a frame.
///
/// **Debug mode moves `Logger.root.level`, not just the panel's visibility.**
/// `AppLogger.debug` maps to `Logger.fine`, which is below `INFO`: without this
/// the records would be filtered out before any sink saw them, and a toggle
/// that reveals an empty panel is worse than no toggle. Turning it off restores
/// `INFO`, so warnings and errors keep their history either way — and detail
/// starts from the moment the switch was flipped, not retroactively.
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
