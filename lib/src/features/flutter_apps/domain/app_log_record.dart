/// Where one line in the debug console came from.
///
/// The console is one list because that is how it is read — a `print`, an
/// exception and a `dart:developer` record are the same investigation — but
/// they arrive on four different VM service streams and mean different things,
/// so the origin travels with the line.
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

  /// Written by this app, not by the running one: attached, reloaded, ended.
  /// In the same list because the console's job is to explain a gap in it.
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

  /// The event's own timestamp where it carries one, our arrival time
  /// otherwise. Never both silently.
  final DateTime at;

  final String message;

  /// `LogRecord.loggerName`, for a `dart:developer` record that named a
  /// channel.
  final String? loggerName;

  /// `LogRecord.level`, on the `package:logging` scale.
  final int? level;

  /// The rest of it: a stack trace, or the body of a structured error.
  final String? detail;

  /// Whether this line was already in the buffer when we attached.
  ///
  /// **The Dart Development Service replays its buffered `Stdout`, `Stderr`,
  /// `Logging` and `Extension` events to every new subscriber**, so the first
  /// burst after `streamListen` is history — the app's startup, and whatever
  /// happened while nobody was watching. That is worth having in a console and
  /// is a lie in a live tail, which is the trap `tool/vm_probe.dart` already
  /// records for `Flutter.Frame`. Marked rather than dropped, so the console
  /// can rule off where we came in.
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

/// A bounded, newest-last buffer of one app's console.
///
/// Bounded because a chatty app writes without limit and this is held in
/// memory for the life of a connection; [dropped] is a **count**, never a
/// duration, so the console can say what it lost without pretending to know
/// when.
class AppLogBuffer {
  AppLogBuffer({this.capacity = 2000}) : assert(capacity > 0);

  final int capacity;
  final List<AppLogRecord> _records = <AppLogRecord>[];
  int _dropped = 0;

  /// Lines discarded to stay within [capacity], oldest first.
  int get dropped => _dropped;

  int get length => _records.length;

  List<AppLogRecord> get records => List<AppLogRecord>.unmodifiable(_records);

  void add(AppLogRecord record) {
    _records.add(record);
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
