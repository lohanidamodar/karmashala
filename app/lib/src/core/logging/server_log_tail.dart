import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import 'diagnostics_providers.dart';

/// The end of `server.log`, read back into the entries the server wrote, so
/// the Logs tab filters it as it filters the app's own tail.
class ServerLogTail {
  ServerLogTail(this.file, {this.maxBytes = 512 * 1024});

  final File file;

  /// How much of the file's end is read: the server rotates at 2 MiB.
  final int maxBytes;

  int? _length;
  DateTime? _modified;
  List<LogEntry>? _entries;

  /// The tail, or null while the server has written no log. The same list
  /// while the file is unchanged, so a caller can skip repainting on identity.
  Future<List<LogEntry>?> read() async {
    try {
      final stat = await file.stat();
      if (stat.type == FileSystemEntityType.notFound) {
        _length = _modified = _entries = null;
        return null;
      }
      if (_entries != null &&
          stat.size == _length &&
          stat.modified == _modified) {
        return _entries;
      }
      final start = stat.size > maxBytes ? stat.size - maxBytes : 0;
      final raf = await file.open();
      final List<int> bytes;
      try {
        await raf.setPosition(start);
        bytes = await raf.read(stat.size - start);
      } finally {
        await raf.close();
      }
      _length = stat.size;
      _modified = stat.modified;
      return _entries = parseLogFile(
        utf8.decode(bytes, allowMalformed: true),
        startsMidLine: start > 0,
      );
    } on FileSystemException {
      return _entries;
    }
  }
}

final _line = RegExp(
  r'^(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\.(\d{3}) (\S) ([^:]*): (.*)$',
);

Level _levelOf(String letter) => switch (letter) {
  'S' => Level.SEVERE,
  'W' => Level.WARNING,
  'C' => Level.CONFIG,
  'F' => Level.FINE,
  _ => Level.INFO,
};

/// [text] as `LogEntry.format(withDate: true)` lines. A line that is not one
/// (a stack trace) continues the entry above it; [startsMidLine] drops the
/// first line, which a read from the middle of the file cut.
List<LogEntry> parseLogFile(String text, {bool startsMidLine = false}) {
  final lines = const LineSplitter().convert(text);
  final entries = <LogEntry>[];
  for (final (index, line) in lines.indexed) {
    if (index == 0 && startsMidLine) continue;
    final match = _line.firstMatch(line);
    if (match == null) {
      if (entries.isEmpty || line.isEmpty) continue;
      final last = entries.removeLast();
      entries.add(
        LogEntry(
          sequence: last.sequence,
          time: last.time,
          level: last.level,
          channel: last.channel,
          message: '${last.message}\n$line',
          error: last.error,
        ),
      );
      continue;
    }
    int at(int group) => int.parse(match.group(group)!);
    var message = match.group(10)!;
    String? error;
    final cut = message.lastIndexOf(' | error=');
    if (cut >= 0) {
      error = message.substring(cut + ' | error='.length);
      message = message.substring(0, cut);
    }
    entries.add(
      LogEntry(
        sequence: entries.length,
        time: DateTime(at(1), at(2), at(3), at(4), at(5), at(6), at(7)),
        level: _levelOf(match.group(8)!),
        channel: match.group(9)!,
        message: message,
        error: error,
      ),
    );
  }
  return entries;
}

/// This machine's server log as the Logs tab reads it; null where this
/// machine hosts no server.
final serverLogTailProvider = Provider<ServerLogTail?>((ref) {
  final file = ref.watch(serverLogFileProvider).asData?.value;
  return file == null ? null : ServerLogTail(file);
});
