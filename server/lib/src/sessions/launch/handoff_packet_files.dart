import 'dart:io';

import 'package:path/path.dart' as p;

/// The handoff packets written to disk, one per session, because a large paste
/// into a PTY collapses to `[Pasted text #N]`: the agent is handed the file
/// instead (`<data dir>/handoff`). Swept only when written to.
class HandoffPacketFiles {
  const HandoffPacketFiles(this.directory);

  final Directory directory;

  /// Writes [packet] as [sessionId]'s brief and returns its path on **this**
  /// filesystem, or `null`: a handoff that cannot write a file must still run.
  String? write({
    required String sessionId,
    required String packet,
    required Set<String> liveSessionIds,
  }) {
    try {
      directory.createSync(recursive: true);
      retireAllBut({...liveSessionIds, sessionId});
      final file = File(p.join(directory.path, fileNameFor(sessionId)));
      file.writeAsStringSync(packet, flush: true);
      return file.path;
    } on Object {
      return null;
    }
  }

  /// Retires every packet whose session is not in [keep], and says how many.
  int retireAllBut(Set<String> keep) {
    var retired = 0;
    try {
      if (!directory.existsSync()) return 0;
      final wanted = {for (final id in keep) fileNameFor(id)};
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
      'handoff-${sessionId.replaceAll(RegExp('[^A-Za-z0-9-]'), '_')}.md';
}
