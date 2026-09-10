import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'log_entry.dart';

/// Appends log lines to a rotating file — the only sink that survives the
/// process, and what a bug report attaches.
///
/// [add] never blocks and never throws: it queues a formatted string and arms a
/// timer, and the writes are serialised behind one future chain. A full or gone
/// disk costs the caller nothing and shows up in [lastError].
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

  /// How long records may sit in memory: short enough that a crash loses
  /// ~nothing, long enough that a flood is one write.
  final Duration flushInterval;

  /// The floor for what is written; the buffer keeps everything regardless.
  Level minimumLevel;

  /// The most lines that may queue before the oldest are dropped, so a dead
  /// disk cannot become an out-of-memory.
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

  /// Every log file that exists, newest first.
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
