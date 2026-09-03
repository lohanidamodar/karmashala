import 'dart:io';

import 'package:path/path.dart' as p;

/// One hook payload a spooling agent wrote, as this app reads it back.
///
/// [firedAt] is the spool file's own modification time, not the moment this app
/// got round to reading it, and that distinction is what makes the spool safe
/// to leave lying around: a payload written before an unclean exit is drained
/// on the next launch carrying its real age, so the five-minute window in
/// `AgentStatusService` discards it instead of announcing a stale status as
/// news. Falls back to now only when the file's mtime cannot be read at all.
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

/// Reads and clears the payloads a WSL agent's hook script wrote.
///
/// The other half of `AgentHookInstaller`'s spool transport. The script's write
/// is `printf` + `cat` into a `.part` file and one `mv`, so a file with the
/// `.json` name is always whole — an unfinished write is still called `.part`
/// and is not matched here. Nothing else in this app writes into that
/// directory, and nothing outside the distribution can.
///
/// **Every payload is deleted once it has been read**, whether it parsed or
/// not: a file this cannot understand will not become understandable, and
/// leaving it would make the directory grow without bound for the one reason
/// the cap in the script cannot see.
class AgentHookSpool {
  const AgentHookSpool();

  /// Everything waiting in [directory], oldest first, up to [limit] — and
  /// removed from disk as it is read.
  ///
  /// Ordered by mtime because order is the one thing a hook stream cannot
  /// afford to lose: `PreToolUse` and `Stop` landing in the wrong order would
  /// leave a finished session reading `working` until the next event. Ties fall
  /// back to the file name, which the script makes unique per firing process.
  ///
  /// [limit] bounds a single drain rather than the directory: a launch that
  /// finds a backlog from an unclean exit spreads it over ticks instead of
  /// holding the isolate for a second.
  ///
  /// Never throws. A directory that is gone, a distribution that stopped
  /// answering mid-listing and a file that was deleted between the listing and
  /// the read are all ordinary here, and each of them means "nothing more this
  /// tick".
  List<AgentHookSpoolEvent> drain(Directory directory, {int limit = 64}) {
    final List<FileSystemEntity> entries;
    try {
      if (!directory.existsSync()) return const [];
      entries = directory.listSync(followLinks: false);
    } on FileSystemException {
      return const [];
    }

    final files = <(DateTime, String, File)>[];
    for (final entry in entries) {
      if (entry is! File) continue;
      if (p.extension(entry.path) != '.json') continue;
      try {
        files.add((entry.statSync().modified, p.basename(entry.path), entry));
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
        raw = file.readAsStringSync();
      } on FileSystemException {
        continue;
      }
      try {
        file.deleteSync();
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

  /// One spool file's contents: `agent=` and `event=` headers, a blank line,
  /// then the agent's payload verbatim.
  ///
  /// A header rather than a file name because a name is a place to lose things:
  /// the event names are the agent's (`PostToolUse`, `SessionEnd`) and the
  /// payload is somebody else's JSON, and neither has any business being
  /// escaped into a path. The blank line is the terminator, so a payload that
  /// happens to start with `event=` cannot be read as a header.
  ///
  /// `null` for anything that does not have both headers — a truncated file, or
  /// a file somebody else put there.
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
