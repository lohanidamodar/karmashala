import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'log_entry.dart';

/// Appends log lines to a rotating file.
///
/// **This is the sink that survives.** The ring buffer dies with the process
/// and the console does not exist in a windowed release build, so a crash, a
/// hang, or "it did this yesterday" has nothing to read without a file. It is
/// also what a bug report attaches.
///
/// **[add] never blocks and never throws.** It appends one already-formatted
/// string to an in-memory queue and arms a timer; the write, the `stat` and the
/// rotation all happen later, off the caller's stack, serialised behind a
/// single future chain so two flushes cannot interleave. A disk that is full,
/// read-only or gone costs the caller nothing — the failure is recorded in
/// [lastError] for the settings screen to show, and logging carries on.
class LogFileSink {
  LogFileSink({
    required this.directory,
    this.fileName = 'karmashala.log',
    this.maxBytes = 2 * 1024 * 1024,
    this.keep = 3,
    this.flushInterval = const Duration(milliseconds: 400),
    this.minimumLevel = Level.INFO,
    this.maxPending = 20000,
  });

  /// Where the files live. Created on first write.
  final Directory directory;

  final String fileName;

  /// Rotate once the live file passes this size.
  final int maxBytes;

  /// How many files to keep, the live one included.
  final int keep;

  /// How long records may sit in memory before they are written. Short enough
  /// that a crash loses ~nothing, long enough that a flood is one write.
  final Duration flushInterval;

  /// The floor for what is written. The buffer keeps everything regardless;
  /// this is only about how much of it is worth spending disk on.
  Level minimumLevel;

  /// The most lines that may queue before the oldest are dropped — the bound
  /// that stops a dead disk from turning into an out-of-memory.
  final int maxPending;

  final Queue<String> _pending = ListQueue<String>();
  Timer? _timer;
  Future<void> _chain = Future<void>.value();
  bool _closed = false;
  int _droppedPending = 0;
  String? _lastError;

  /// The live file. Rotated copies are `karmashala.1.log`, `.2.log`, …
  File get file => File(p.join(directory.path, fileName));

  /// Why the last write failed, or null. Shown in Settings → Diagnostics.
  String? get lastError => _lastError;

  /// Lines dropped because the queue was full (a disk that stopped answering).
  int get droppedPending => _droppedPending;

  /// Queues [entry]. Returns immediately.
  void add(LogEntry entry) {
    if (_closed || entry.level < minimumLevel) return;
    if (_pending.length >= maxPending) {
      _pending.removeFirst();
      _droppedPending++;
    }
    _pending.add(entry.format(withDate: true, withStackTrace: true));
    _timer ??= Timer(flushInterval, () {
      _timer = null;
      unawaited(flush());
    });
  }

  /// Writes everything queued. Awaiting it awaits every write queued before it.
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    return _chain = _chain.then((_) => _writeOnce());
  }

  /// Flushes and stops accepting records.
  Future<void> close() async {
    await flush();
    _closed = true;
  }

  /// Every log file that exists, newest first — what "copy report" attaches and
  /// what the reveal button points at.
  Future<List<File>> files() async {
    final out = <File>[];
    if (await file.exists()) out.add(file);
    for (var i = 1; i < keep; i++) {
      final rotated = _rotated(i);
      if (await rotated.exists()) out.add(rotated);
    }
    return out;
  }

  File _rotated(int index) {
    final ext = p.extension(fileName);
    final stem = p.basenameWithoutExtension(fileName);
    return File(p.join(directory.path, '$stem.$index$ext'));
  }

  Future<void> _writeOnce() async {
    if (_pending.isEmpty) return;
    final lines = _pending.join('\n');
    _pending.clear();
    try {
      if (!await directory.exists()) await directory.create(recursive: true);
      final live = file;
      await live.writeAsString('$lines\n', mode: FileMode.append);
      await _rotateIfNeeded(live);
      _lastError = null;
    } catch (error) {
      // A log sink that can take the app down with it is worse than no sink.
      _lastError = error.toString();
    }
  }

  Future<void> _rotateIfNeeded(File live) async {
    if (await live.length() < maxBytes) return;
    for (var i = keep - 1; i >= 1; i--) {
      final older = _rotated(i);
      if (!await older.exists()) continue;
      if (i == keep - 1) {
        await older.delete();
      } else {
        await older.rename(_rotated(i + 1).path);
      }
    }
    if (keep > 1) {
      await live.rename(_rotated(1).path);
    } else {
      await live.delete();
    }
  }
}
