import 'dart:io';

import 'package:path/path.dart' as p;

/// One hook payload a spooling agent wrote, as this app reads it back.
///
/// [firedAt] is the spool file's own mtime, not when this app got round to
/// reading it, which is what makes the spool safe to leave lying around: a
/// payload from before an unclean exit is drained carrying its real age, so
/// `AgentStatusService`'s five-minute window discards it instead of announcing
/// a stale status as news. Falls back to now only when the mtime cannot be
/// read.
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
/// The other half of `AgentHookInstaller`'s spool transport. The script writes a
/// `.part` file and one `mv`, so a file with the `.json` name is always whole.
///
/// **Every payload is deleted once it has been read**, whether it parsed or not:
/// a file this cannot understand will not become understandable, and leaving it
/// would grow the directory for the one reason the script's own cap cannot
/// see.
class AgentHookSpool {
  const AgentHookSpool();

  /// Everything waiting in [directory], oldest first, up to [limit] — and
  /// removed from disk as it is read.
  ///
  /// Ordered by mtime because order is the one thing a hook stream cannot afford
  /// to lose: `PreToolUse` and `Stop` the wrong way round leave a finished
  /// session reading `working` until the next event. Ties fall back to the file
  /// name, which the script makes unique per firing process. [limit] bounds one
  /// drain rather than the directory, so a backlog from an unclean exit is
  /// spread over ticks.
  ///
  /// **Asynchronous on purpose**: every path here is a `\\wsl.localhost` UNC
  /// path served by a plan9 daemon *inside* the distribution, and a synchronous
  /// Dart file operation has no timeout, so one that does not come back holds
  /// the isolate — which `AgentHookSpoolDrainer` would meet every 400 ms.
  /// Measured 2026-09-04 on the owner's machine, distribution warm: `exists`
  /// 1 ms, `list` 16 ms, and 84 ms for a name that is not a distribution at all.
  /// Nothing here is slow *when it answers*; the reason to be off the isolate is
  /// the case where it does not.
  ///
  /// Never throws: a directory that is gone, a distribution that stopped
  /// answering mid-listing and a file deleted between the listing and the read
  /// all mean "nothing more this tick".
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

  /// One spool file's contents: `agent=` and `event=` headers, a blank line,
  /// then the agent's payload verbatim.
  ///
  /// Headers rather than a file name because the event names are the agent's and
  /// the payload is somebody else's JSON, and neither has business being escaped
  /// into a path. The blank line terminates the headers, so a payload starting
  /// with `event=` cannot be read as one. `null` unless both headers are
  /// present.
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
