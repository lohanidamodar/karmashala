import 'dart:io';

import 'package:path/path.dart' as p;

/// One hook payload a spooling agent wrote. [firedAt] is the file's own mtime,
/// so one written before an unclean exit is drained carrying its real age.
class AgentHookSpoolEvent {
  const AgentHookSpoolEvent({
    required this.agentId,
    required this.event,
    required this.body,
    required this.firedAt,
  });

  final String agentId;
  final String event;

  /// The agent's own JSON payload, exactly as it came off stdin.
  final String body;

  final DateTime firedAt;
}

/// Reads and clears the payloads a WSL agent's hook script wrote. Every payload
/// is deleted once read, parsed or not; a `.json` name is always a whole file.
class AgentHookSpool {
  const AgentHookSpool();

  /// Everything waiting in [directory], oldest first, up to [limit], removed as
  /// it is read. Ordered by mtime, never throws, and never synchronous.
  Future<List<AgentHookSpoolEvent>> drain(
    Directory directory, {
    int limit = 64,
  }) async {
    final List<FileSystemEntity> entries;
    try {
      if (!await directory.exists()) return const [];
      entries = await directory.list(followLinks: false).toList();
    } on FileSystemException {
      return const [];
    }

    final files = <(DateTime, String, File)>[];
    for (final entry in entries) {
      if (entry is! File) continue;
      if (p.extension(entry.path) != '.json') continue;
      try {
        final stat = await entry.stat();
        files.add((stat.modified, p.basename(entry.path), entry));
      } on FileSystemException {
        continue;
      }
    }
    files.sort((a, b) {
      final byTime = a.$1.compareTo(b.$1);
      return byTime != 0 ? byTime : a.$2.compareTo(b.$2);
    });

    final events = <AgentHookSpoolEvent>[];
    for (final (modified, _, file) in files.take(limit)) {
      String raw;
      try {
        raw = await file.readAsString();
      } on FileSystemException {
        continue;
      }
      try {
        await file.delete();
      } on FileSystemException {
        // Read but not removable: skip it rather than report it twice on every
        // tick for the rest of the run.
        continue;
      }
      final event = parse(raw, firedAt: modified);
      if (event != null) events.add(event);
    }
    return events;
  }

  /// `agent=` and `event=` headers, a blank line, then the payload verbatim —
  /// the blank line terminates, so a payload starting `event=` is not one.
  AgentHookSpoolEvent? parse(String raw, {required DateTime firedAt}) {
    var agentId = '';
    var event = '';
    var index = 0;
    while (true) {
      final end = raw.indexOf('\n', index);
      if (end < 0) return null;
      final line = raw.substring(index, end);
      index = end + 1;
      if (line.isEmpty) break;
      if (line.startsWith('agent=')) {
        agentId = line.substring('agent='.length);
      } else if (line.startsWith('event=')) {
        event = line.substring('event='.length);
      } else {
        return null;
      }
    }
    if (agentId.isEmpty || event.isEmpty) return null;
    return AgentHookSpoolEvent(
      agentId: agentId,
      event: event,
      body: raw.substring(index),
      firedAt: firedAt,
    );
  }
}
