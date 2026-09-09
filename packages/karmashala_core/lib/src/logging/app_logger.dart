import 'dart:async';

import 'package:logging/logging.dart';

import 'diagnostics.dart';

/// Central logging abstraction for the application.
///
/// Features must log through an [AppLogger] rather than calling `print`, so that
/// there is a single place to control formatting, routing, and (in later loops)
/// persistence or streaming to the future remote companion app.
///
/// This wraps the `logging` package's [Logger] but keeps the surface small and
/// intent-revealing so the backing implementation can change without touching
/// call sites.
class AppLogger {
  AppLogger(this._logger);

  /// Creates a logger scoped to [name] (typically a feature or component name).
  factory AppLogger.named(String name) => AppLogger(Logger(name));

  final Logger _logger;

  /// Installs a single root logging handler for the whole application.
  ///
  /// Call once during bootstrap, before any logging occurs. [level] controls the
  /// minimum severity that is emitted; [onRecord] replaces the default fan-out
  /// (a test collecting records, and nothing else).
  ///
  /// Calling it again replaces the previous handler rather than adding a second
  /// one, so a re-initialise cannot double every line.
  static void initialize({
    Level level = Level.INFO,
    void Function(LogRecord record)? onRecord,
  }) {
    Logger.root.level = level;
    unawaited(_subscription?.cancel());
    _subscription = Logger.root.onRecord.listen(
      onRecord ?? Diagnostics.instance.handle,
    );
  }

  static StreamSubscription<LogRecord>? _subscription;

  void debug(String message) => _logger.fine(message);

  void info(String message) => _logger.info(message);

  void warning(String message, [Object? error, StackTrace? stackTrace]) =>
      _logger.warning(message, error, stackTrace);

  void error(String message, [Object? error, StackTrace? stackTrace]) =>
      _logger.severe(message, error, stackTrace);
}
