import 'package:logging/logging.dart';

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
  /// minimum severity that is emitted.
  static void initialize({
    Level level = Level.INFO,
    void Function(LogRecord record)? onRecord,
  }) {
    Logger.root.level = level;
    Logger.root.onRecord.listen(onRecord ?? _defaultHandler);
  }

  static void _defaultHandler(LogRecord record) {
    final buffer = StringBuffer()
      ..write('[${record.level.name}] ')
      ..write('${record.loggerName}: ')
      ..write(record.message);
    if (record.error != null) {
      buffer.write(' | error=${record.error}');
    }
    // ignore: avoid_print — this is the single sanctioned output sink.
    print(buffer.toString());
    if (record.stackTrace != null) {
      // ignore: avoid_print
      print(record.stackTrace);
    }
  }

  void debug(String message) => _logger.fine(message);

  void info(String message) => _logger.info(message);

  void warning(String message, [Object? error, StackTrace? stackTrace]) =>
      _logger.warning(message, error, stackTrace);

  void error(String message, [Object? error, StackTrace? stackTrace]) =>
      _logger.severe(message, error, stackTrace);
}
