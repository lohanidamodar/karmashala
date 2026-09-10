import 'package:logging/logging.dart';

import 'log_buffer.dart';
import 'log_entry.dart';
import 'log_file_sink.dart';
import 'log_redactor.dart';

/// The app's log fan-out: the one handler installed on `Logger.root`.
///
/// Every record is redacted once and then fanned out, so no sink can reach the
/// unredacted text. [handle] never blocks and never throws — it is called from
/// pty reads and socket callbacks, so each sink is guarded.
class Diagnostics {
  Diagnostics({
    LogRingBuffer? buffer,
    LogRedactor? redactor,
    this.file,
    this.echoToConsole = true,
  }) : buffer = buffer ?? LogRingBuffer(),
       redactor = redactor ?? LogRedactor();

  /// The process-wide instance the root handler and the UI share. Settable so a
  /// test can install its own.
  static Diagnostics instance = Diagnostics();

  /// The bounded tail of everything logged, and what the panel renders.
  final LogRingBuffer buffer;

  /// Applied to every message, error and stack trace before anything stores it.
  final LogRedactor redactor;

  /// The rotating file, or null when writing to disk is off.
  LogFileSink? file;

  /// Whether records are also printed. Invisible in a windowed release build —
  /// `windows/runner/main.cpp` creates a console only for a parent console or a
  /// debugger — which is why the other sinks exist.
  bool echoToConsole;

  int _sequence = 0;

  /// Redacts [record], captures it and offers it to every sink. The only way
  /// into the sinks, so nothing can arrive unredacted.
  void handle(LogRecord record) {
    final entry = LogEntry(
      sequence: _sequence++,
      time: record.time,
      level: record.level,
      channel: record.loggerName,
      message: redactor.apply(record.message),
      error: redactor.applyOrNull(record.error?.toString()),
      stackTrace: redactor.applyOrNull(record.stackTrace?.toString()),
    );
    _fanOut(entry);
  }

  /// Starts writing to [sink]. [backfill] replays the buffer, because the file
  /// opens only once `path_provider` answers — several hundred milliseconds in,
  /// which is where the interesting bootstrap failures are.
  void attachFile(LogFileSink sink, {bool backfill = true}) {
    file = sink;
    if (!backfill) return;
    for (final entry in buffer.snapshot()) {
      sink.add(entry);
    }
  }

  /// Writes what is queued, now.
  ///
  /// [LogFileSink.add] arms a 400 ms timer owned by this isolate, so a line
  /// logged just before the isolate stops never reaches disk. Anything about to
  /// hold the isolate should flush first.
  Future<void> flushFile() => file?.flush() ?? Future<void>.value();

  /// Stops writing to disk, flushing what is queued.
  Future<void> detachFile() async {
    final sink = file;
    file = null;
    await sink?.close();
  }

  void _fanOut(LogEntry entry) {
    try {
      buffer.add(entry);
    } catch (_) {
      // A broken buffer must not take down the code that logged.
    }
    try {
      file?.add(entry);
    } catch (_) {
      // Nor must a broken disk.
    }
    if (echoToConsole) {
      try {
        // ignore: avoid_print — this is the sanctioned console sink.
        print(entry.format());
        if (entry.stackTrace != null) {
          // ignore: avoid_print
          print(entry.stackTrace);
        }
      } catch (_) {}
    }
  }

  /// Empties the tail. The panel's "clear" button, and how a test starts clean.
  void clear() => buffer.clear();
}
