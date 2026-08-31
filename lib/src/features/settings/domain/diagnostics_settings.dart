import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:logging/logging.dart';

/// Whether debug mode starts on.
///
/// On in a debug build, off in release: a developer running the app already
/// wants the detail, and a shipped build should not pay for `fine` records
/// nobody is reading. The release default is what the toggle is *for*.
const bool kDefaultDebugMode = kDebugMode;

/// How much of the log is written to disk.
///
/// The ring buffer keeps everything it is given whatever this says; this is
/// only about how much of it is worth spending disk on, and it is what the
/// panel's level filter starts at.
enum LogVerbosity {
  /// Only what went wrong. Small files, and enough for most bug reports.
  warnings('Warnings and errors', Level.WARNING),

  /// The default. Adds the handful of lines that say what the app decided —
  /// what it started, what it discovered, which session it resumed.
  normal('Normal', Level.INFO),

  /// Everything, including `AppLogger.debug`. Only reaches the sinks while
  /// debug mode is on, because the root logger filters `fine` out otherwise.
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
