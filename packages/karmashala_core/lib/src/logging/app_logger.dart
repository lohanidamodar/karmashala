import 'dart:async';

import 'package:logging/logging.dart';

import 'diagnostics.dart';

/// Central logging abstraction. Features log through this rather than `print`,
/// so formatting, routing and persistence have one place to change.
class AppLogger {
  AppLogger(this._logger);

  /// A logger scoped to [name] — a feature or component.
  factory AppLogger.named(String name) => AppLogger(Logger(name));

  final Logger _logger;

  /// Installs the one root handler. Call during bootstrap; [onRecord] replaces
  /// the default fan-out. A second call replaces the handler rather than adding
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
