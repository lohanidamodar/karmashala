/// Where one line in the debug console came from: one list, but four VM
/// service streams, so the origin travels with the line.
enum AppLogSource {
  /// The `Stdout` stream. `print` and `stdout.write`, base64 in the event.
  stdout,

  /// The `Stderr` stream.
  stderr,

  /// The `Logging` stream: one `LogRecord` per `dart:developer` `log()` call.
  developerLog,

  /// A `Flutter.Error` on the `Extension` stream — a caught framework
  /// exception, already structured.
  flutterError,

  /// Written by this app, not the running one — in the same list because the
  /// console's job is to explain a gap in it.
  lifecycle,
}

/// One line in a running app's debug console.
class AppLogRecord {
  const AppLogRecord({
    required this.source,
    required this.at,
    required this.message,
    this.loggerName,
    this.level,
    this.detail,
    this.beforeAttach = false,
  });

  final AppLogSource source;

  /// The event's own timestamp where it carries one, our arrival time else.
  final DateTime at;

  final String message;

  /// `LogRecord.loggerName`, when the record named a channel.
  final String? loggerName;

  /// `LogRecord.level`, on the `package:logging` scale.
  final int? level;

  /// The rest of it: a stack trace, or the body of a structured error.
  final String? detail;

  /// Whether this line was already buffered when we attached: DDS replays its
  /// buffer to every new subscriber, so the first burst is history — marked
  /// rather than dropped, because it is a lie in a live tail.
  final bool beforeAttach;

  bool get isError =>
      source == AppLogSource.stderr || source == AppLogSource.flutterError;

  Map<String, Object?> toJson() => <String, Object?>{
    'source': source.name,
    'at': at.toIso8601String(),
    'message': message,
    if (loggerName != null) 'logger': loggerName,
    if (level != null) 'level': level,
    if (detail != null) 'detail': detail,
    if (beforeAttach) 'beforeAttach': true,
  };
}

/// A bounded, newest-last buffer of one app's console. [dropped] is a count,
/// never a duration: the console says what it lost, not when.
class AppLogBuffer {
  AppLogBuffer({this.capacity = 2000}) : assert(capacity > 0);

  final int capacity;
  final List<AppLogRecord> _records = <AppLogRecord>[];
  int _dropped = 0;
  int _appended = 0;

  /// Lines discarded to stay within [capacity], oldest first.
  int get dropped => _dropped;

  int get length => _records.length;

  List<AppLogRecord> get records => List<AppLogRecord>.unmodifiable(_records);

  /// Every record ever added, never reset: a record's sequence number is its
  /// place in this count, so it survives both dropping and [clear].
  int get appended => _appended;

  /// The sequence number of the oldest record still held.
  int get firstSequence => _appended - _records.length;

  /// The records numbered [sequence] and newer, oldest first.
  List<AppLogRecord> since(int sequence) {
    final start = sequence - firstSequence;
    if (start <= 0) return List<AppLogRecord>.unmodifiable(_records);
    if (start >= _records.length) return const <AppLogRecord>[];
    return List<AppLogRecord>.unmodifiable(_records.sublist(start));
  }

  void add(AppLogRecord record) {
    _records.add(record);
    _appended = _appended + 1;
    if (_records.length > capacity) {
      _records.removeRange(0, _records.length - capacity);
      _dropped = _dropped + 1;
    }
  }

  /// The newest [limit] lines, oldest first, optionally of one origin only.
  List<AppLogRecord> tail({int limit = 100, Set<AppLogSource>? sources}) {
    final matching = sources == null
        ? _records
        : _records.where((r) => sources.contains(r.source)).toList();
    if (matching.length <= limit) {
      return List<AppLogRecord>.unmodifiable(matching);
    }
    return List<AppLogRecord>.unmodifiable(
      matching.sublist(matching.length - limit),
    );
  }

  void clear() {
    _records.clear();
    _dropped = 0;
  }
}
