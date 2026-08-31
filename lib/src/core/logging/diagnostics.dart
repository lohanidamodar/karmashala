import 'package:logging/logging.dart';

import 'log_buffer.dart';
import 'log_entry.dart';
import 'log_file_sink.dart';
import 'log_redactor.dart';

/// The app's log fan-out: the one handler installed on `Logger.root`.
///
/// **Why this exists.** Before it, the root handler ended in `print`, and
/// `windows/runner/main.cpp` only creates a console when a parent console or a
/// debugger is already there. A release build launched from Explorer, the Start
/// menu or the tray has neither — so every warning the app wrote went nowhere,
/// and a pairing that failed in the field left no evidence at all.
///
/// Every record is redacted once, captured into a [LogEntry], and then handed
/// to each sink. Fanning out from a single sanitised entry (rather than letting
/// each sink read the raw [LogRecord]) is what makes it structurally impossible
/// for the panel, the clipboard, the report or the log file to be the one that
/// leaks: none of them can reach the unredacted text, because it was never
/// stored.
///
/// **[handle] must never block the caller and never throw.** Logging sits
/// inside pty reads, socket callbacks and status cycles; a sink that is slow or
/// broken must cost the code that logged nothing more than a `try`. So each
/// sink is guarded, and the only work done inline is a ring-buffer store.
class Diagnostics {
  Diagnostics({
    LogRingBuffer? buffer,
    LogRedactor? redactor,
    this.file,
    this.echoToConsole = true,
  }) : buffer = buffer ?? LogRingBuffer(),
       redactor = redactor ?? LogRedactor();

  /// The process-wide instance the root handler and the UI share.
  ///
  /// Settable so a test can install its own and throw it away afterwards.
  static Diagnostics instance = Diagnostics();

  /// The bounded tail of everything logged, and what the panel renders.
  final LogRingBuffer buffer;

  /// Applied to every message, error and stack trace before anything stores it.
  final LogRedactor redactor;

  /// The rotating file, or null when writing to disk is off. The sink that
  /// outlives the process, and the one a bug report attaches.
  LogFileSink? file;

  /// Whether records are also printed. Free, and still the right sink under
  /// `flutter run`; invisible in a windowed release build, which is the whole
  /// reason the other sinks exist.
  bool echoToConsole;

  int _sequence = 0;

  /// Redacts [record], captures it and offers it to every sink. Safe to call
  /// from anywhere: it is the only way into the sinks, so nothing can arrive
  /// unredacted.
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

  /// Starts writing to [sink].
  ///
  /// [backfill] replays what the buffer already holds, because the file can
  /// only be opened after `path_provider` answers — several hundred
  /// milliseconds into a launch, which is exactly where the interesting
  /// bootstrap failures are.
  void attachFile(LogFileSink sink, {bool backfill = true}) {
    file = sink;
    if (!backfill) return;
    for (final entry in buffer.snapshot()) {
      sink.add(entry);
    }
  }

  /// Stops writing to disk, flushing what is queued.
  Future<void> detachFile() async {
    final sink = file;
    file = null;
    await sink?.close();
  }

  /// Fans one sanitised entry out to the sinks, guarding each.
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
