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
    this.paneSessionId,
  });

  final String agentId;
  final String event;

  /// The `KARMASHALA_SESSION_ID` of the pane the hook fired in, or null from a
  /// script that predates it or a process Karmashala did not launch.
  final String? paneSessionId;

  /// The agent's own JSON payload, exactly as it came off stdin.
  final String body;

  final DateTime firedAt;
}

/// Reads and clears the payloads a WSL agent's hook script wrote. Every payload
/// is deleted once read, parsed or not; a `.json` name is always a whole file.
///
/// Two readers: [drain] opens the files from this process, and is what a
/// spool on this machine's own filesystem uses; a spool inside a WSL
/// distribution is read with [wslDrainScript] through `wsl.exe`, so a Windows
/// host never opens one over `\\wsl.localhost`.
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

  /// Whether [directory] holds a finished payload, answered from its **names
  /// alone**: nothing is opened. Never throws.
  ///
  /// This is the only look a Windows host takes at a WSL spool through
  /// `\\wsl.localhost`. On-access antivirus scans a file when it is *opened*,
  /// and a hook payload is the agent's own words — the prompt, a Bash command
  /// it ran — so Bitdefender flagged a spool file read over the share as
  /// `CMD:Heur…Boxter` and denied the read (docs/windows-antivirus.md). The
  /// contents are read from inside the distribution instead: [wslDrainScript].
  Future<bool> hasPayloads(Directory directory) async {
    try {
      if (!await directory.exists()) return false;
      await for (final entry in directory.list(followLinks: false)) {
        if (entry is File && p.extension(entry.path) == '.json') return true;
      }
    } on FileSystemException {
      return false;
    }
    return false;
  }

  /// The `sh` that drains a spool **from inside its distribution**, so the
  /// payloads cross to Windows over `wsl.exe`'s stdout pipe and are never
  /// opened on a Windows-scanned path. `$1` is the directory, `$2` the limit.
  ///
  /// Oldest first (`ls -tr`, name breaking a tie, as [drain] orders), each
  /// record `<name>\n<mtime seconds>\n<file bytes>` then a NUL — a byte no JSON
  /// document and no header contains. Each file is removed as soon as it has
  /// been copied out, and a `.part` older than two minutes (a hook killed
  /// mid-write) is swept, so the directory stays small.
  static const String wslDrainScript = r'''
dir=$1
limit=$2
cd -- "$dir" 2>/dev/null || exit 0
find . -maxdepth 1 -name '*.part' -mmin +2 -exec rm -f {} \; 2>/dev/null
n=0
ls -1tr 2>/dev/null | while IFS= read -r f; do
  case $f in *.json) ;; *) continue ;; esac
  [ "$n" -lt "$limit" ] || break
  [ -f "$f" ] || continue
  t=$(date -r "$f" +%s 2>/dev/null) || t=
  [ -n "$t" ] || t=$(stat -c %Y "$f" 2>/dev/null) || t=0
  printf '%s\n%s\n' "$f" "$t"
  cat -- "$f" 2>/dev/null
  rm -f -- "$f"
  printf '\000'
  n=$((n+1))
done
exit 0
''';

  /// The `wsl.exe` arguments that run [wslDrainScript] over [linuxDirectory]
  /// in [distribution]. `--exec`, so no login shell re-parses the script.
  static List<String> wslDrainArguments({
    required String distribution,
    required String linuxDirectory,
    int limit = 64,
  }) => [
    '-d',
    distribution,
    '--exec',
    'sh',
    '-c',
    wslDrainScript,
    'karmashala-spool',
    linuxDirectory,
    '$limit',
  ];

  /// The events in what [wslDrainScript] printed, in the order it printed
  /// them. A record cut short — the reader killed mid-file — is dropped.
  List<AgentHookSpoolEvent> parseDrained(String output) {
    final records = output.split('\u0000');
    // Whatever follows the last NUL is either nothing or a record that never
    // finished; neither is an event.
    records.removeLast();
    final events = <AgentHookSpoolEvent>[];
    for (final record in records) {
      final nameEnd = record.indexOf('\n');
      if (nameEnd < 0) continue;
      final timeEnd = record.indexOf('\n', nameEnd + 1);
      if (timeEnd < 0) continue;
      final seconds = int.tryParse(record.substring(nameEnd + 1, timeEnd));
      final event = parse(
        record.substring(timeEnd + 1),
        firedAt: seconds == null || seconds <= 0
            ? DateTime.now()
            : DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true),
      );
      if (event != null) events.add(event);
    }
    return events;
  }

  /// The path inside the distribution of a `\\wsl.localhost\<distro>\…` (or
  /// `\\wsl$\<distro>\…`) directory, or `null` when [path] is not one.
  static String? wslLinuxPathOf(String path) {
    final match = RegExp(
      r'^[\\/]{2}wsl(?:\.localhost|\$)[\\/]+[^\\/]+(.*)$',
      caseSensitive: false,
    ).firstMatch(path);
    if (match == null) return null;
    final rest = match.group(1)!.replaceAll('\\', '/');
    final trimmed = rest.replaceAll(RegExp(r'/+$'), '');
    return trimmed.isEmpty ? '/' : trimmed;
  }

  /// `agent=`, `event=` and an optional `session=` header, a blank line, then
  /// the payload verbatim — the blank line terminates, so a payload starting
  /// `event=` is not one.
  AgentHookSpoolEvent? parse(String raw, {required DateTime firedAt}) {
    var agentId = '';
    var event = '';
    var session = '';
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
      } else if (line.startsWith('session=')) {
        session = line.substring('session='.length);
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
      paneSessionId: session.isEmpty ? null : session,
    );
  }
}
