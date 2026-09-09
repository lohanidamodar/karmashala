/// Android log priority, as it appears in `logcat -v threadtime` output.
enum LogLevel {
  verbose('V'),
  debug('D'),
  info('I'),
  warning('W'),
  error('E'),
  fatal('F');

  const LogLevel(this.code);

  final String code;

  static LogLevel? fromCode(String code) {
    for (final level in LogLevel.values) {
      if (level.code == code) return level;
    }
    return null;
  }

  /// Whether this level is at least as severe as [min].
  bool atLeast(LogLevel min) => index >= min.index;
}

/// One parsed line of `logcat -v threadtime`.
class LogcatEntry {
  const LogcatEntry({
    required this.timestamp,
    required this.pid,
    required this.tid,
    required this.level,
    required this.tag,
    required this.message,
  });

  /// The raw timestamp text as logged (`MM-DD HH:MM:SS.mmm`). Kept as text
  /// because logcat omits the year, so building a `DateTime` would guess.
  final String timestamp;
  final int pid;
  final int tid;
  final LogLevel level;
  final String tag;
  final String message;

  @override
  String toString() => '$timestamp $pid $tid ${level.code} $tag: $message';
}
