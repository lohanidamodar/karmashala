import 'package:logging/logging.dart';

/// One captured log line, **already redacted**.
///
/// Redaction happens on the way in (see [LogRedactor]) rather than in each
/// consumer, so the panel, the clipboard, the report and the log file all read
/// the same sanitised text and none of them can be the one that leaks.
class LogEntry {
  const LogEntry({
    required this.sequence,
    required this.time,
    required this.level,
    required this.channel,
    required this.message,
    this.error,
    this.stackTrace,
  });

  /// Monotonic per-run counter. Survives eviction, so "1,204 lines dropped"
  /// and "is this the same line I was looking at" are both answerable.
  final int sequence;

  final DateTime time;
  final Level level;

  /// The `Logger` name — `remote`, `ssh.connection`, `sessions`, …
  final String channel;

  final String message;
  final String? error;
  final String? stackTrace;

  /// `12:04:31.907 W remote: message | error=…`
  ///
  /// [withDate] adds the day, which the file wants (it outlives a session) and
  /// the panel does not (every row would carry the same eight characters).
  String format({bool withDate = false, bool withStackTrace = false}) {
    final buffer = StringBuffer();
    if (withDate) {
      buffer.write(
        '${_pad(time.year, 4)}-${_pad(time.month, 2)}-${_pad(time.day, 2)} ',
      );
    }
    buffer
      ..write(timestamp)
      ..write(' ')
      ..write(level.name[0])
      ..write(' ')
      ..write(channel)
      ..write(': ')
      ..write(message);
    if (error != null) buffer.write(' | error=$error');
    if (withStackTrace && stackTrace != null) buffer.write('\n$stackTrace');
    return buffer.toString();
  }

  /// `12:04:31.907` — what the panel shows in its left column.
  String get timestamp =>
      '${_pad(time.hour, 2)}:${_pad(time.minute, 2)}:${_pad(time.second, 2)}'
      '.${_pad(time.millisecond, 3)}';

  static String _pad(int value, int width) =>
      value.toString().padLeft(width, '0');
}
