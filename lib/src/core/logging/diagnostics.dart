import 'package:logging/logging.dart';

import 'log_buffer.dart';
import 'log_entry.dart';

/// The app's log fan-out: the one handler installed on `Logger.root`.
///
/// **Why this exists.** Before it, the root handler ended in `print`, and
/// `windows/runner/main.cpp` only creates a console when a parent console or a
/// debugger is already there. A release build launched from Explorer, the Start
/// menu or the tray has neither — so every warning the app wrote went nowhere,
/// and a pairing that failed in the field left no evidence at all.
///
/// Every record is captured once into a [LogEntry] and then handed to each
/// sink. Fanning out from a single captured entry (rather than letting each
/// sink read the raw [LogRecord]) is what makes it impossible for one of them
/// to skip a step the others took — redaction, most importantly.
///
/// **[handle] must never block the caller and never throw.** Logging sits
/// inside pty reads, socket callbacks and status cycles; a sink that is slow or
/// broken must cost the code that logged nothing more than a `try`. So each
/// sink is guarded, and the only work done inline is a ring-buffer store.
class Diagnostics {
  Diagnostics({LogRingBuffer? buffer, this.echoToConsole = true})
    : buffer = buffer ?? LogRingBuffer();

  /// The process-wide instance the root handler and the UI share.
  ///
  /// Settable so a test can install its own and throw it away afterwards.
  static Diagnostics instance = Diagnostics();

  /// The bounded tail of everything logged, and what the panel renders.
  final LogRingBuffer buffer;

  /// Whether records are also printed. Free, and still the right sink under
  /// `flutter run`; invisible in a windowed release build, which is the whole
  /// reason the other sinks exist.
  bool echoToConsole;

  int _sequence = 0;

  /// Captures [record] and offers it to every sink. Safe to call from anywhere.
  void handle(LogRecord record) {
    final entry = LogEntry(
      sequence: _sequence++,
      time: record.time,
      level: record.level,
      channel: record.loggerName,
      message: record.message,
      error: record.error?.toString(),
      stackTrace: record.stackTrace?.toString(),
    );
    add(entry);
  }

  /// Fans one already-captured entry out to the sinks, guarding each.
  void add(LogEntry entry) {
    try {
      buffer.add(entry);
    } catch (_) {
      // A broken buffer must not take down the code that logged.
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
