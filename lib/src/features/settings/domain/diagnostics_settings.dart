import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:logging/logging.dart';

/// Whether debug mode starts on: on in a debug build, off in release — a
/// shipped build should not pay for `fine` records nobody is reading.
const bool kDefaultDebugMode = kDebugMode;

/// How much of the log is written to disk. The ring buffer keeps everything it
/// is given regardless; this is only what is worth spending disk on.
enum LogVerbosity {
  /// Only what went wrong. Small files, and enough for most bug reports.
  warnings('Warnings and errors', Level.WARNING),

  /// The default: the handful of lines saying what the app decided.
  normal('Normal', Level.INFO),

  /// Everything, including `AppLogger.debug` — which reaches a sink only while
  /// debug mode is on, since the root logger filters `fine` out otherwise.
  verbose('Everything', Level.ALL);

  const LogVerbosity(this.label, this.level);

  final String label;

  /// The floor this verbosity puts on the file sink.
  final Level level;

  static LogVerbosity fromName(Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return normal;
  }
}
