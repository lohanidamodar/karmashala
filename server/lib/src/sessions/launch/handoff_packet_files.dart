import 'dart:io';

import 'package:path/path.dart' as p;

/// The texts written to disk for a session's launch, because its command line
/// cannot carry them (`<data dir>/handoff`), at most one of each kind per
/// session. A handoff packet, because a large paste into a PTY collapses to
/// `[Pasted text #N]`; an opening prompt, because a Windows-native launch
/// splits or truncates one with a quote or a newline in it
/// (`survivesWindowsNativeArgv`). The agent is handed the file instead. Swept
/// only when written to.
class HandoffPacketFiles {
  const HandoffPacketFiles(this.directory);

  final Directory directory;

  /// Writes [packet] as [sessionId]'s brief and returns its path on **this**
  /// filesystem, or `null`: a handoff that cannot write a file must still run.
  String? write({
    required String sessionId,
    required String packet,
    required Set<String> liveSessionIds,
  }) => _write(fileNameFor(sessionId), sessionId, packet, liveSessionIds);

  /// Writes [prompt] as [sessionId]'s opening message, byte for byte in UTF-8,
  /// and returns its path on **this** filesystem, or `null`.
  String? writePrompt({
    required String sessionId,
    required String prompt,
    required Set<String> liveSessionIds,
  }) => _write(promptFileNameFor(sessionId), sessionId, prompt, liveSessionIds);

  String? _write(
    String name,
    String sessionId,
    String text,
    Set<String> liveSessionIds,
  ) {
    try {
      directory.createSync(recursive: true);
      retireAllBut({...liveSessionIds, sessionId});
      final file = File(p.join(directory.path, name));
      file.writeAsStringSync(text, flush: true);
      return file.path;
    } on Object {
      return null;
    }
  }

  /// Retires every file whose session is not in [keep], and says how many.
  int retireAllBut(Set<String> keep) {
    var retired = 0;
    try {
      if (!directory.existsSync()) return 0;
      final wanted = {
        for (final id in keep) ...[fileNameFor(id), promptFileNameFor(id)],
      };
      for (final entity in directory.listSync()) {
        if (entity is! File) continue;
        if (wanted.contains(p.basename(entity.path))) continue;
        try {
          entity.deleteSync();
          retired++;
        } on Object {
          // Held open by something else; the next write tries again.
        }
      }
    } on Object {
      // An unreadable directory retires nothing and fails nothing.
    }
    return retired;
  }

  /// Session ids are UUIDs, so this changes nothing in practice — but a file
  /// name built from a database row is not the place to find out otherwise.
  static String fileNameFor(String sessionId) =>
      'handoff-${_safe(sessionId)}.md';

  /// The opening-prompt file's name, beside [fileNameFor]'s.
  static String promptFileNameFor(String sessionId) =>
      'prompt-${_safe(sessionId)}.md';

  static String _safe(String sessionId) =>
      sessionId.replaceAll(RegExp('[^A-Za-z0-9-]'), '_');
}
