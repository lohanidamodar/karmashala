import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/paths/app_support_directory.dart';

/// The handoff packets written to disk, so an agent can be **given** the brief
/// rather than have it typed at it.
///
/// One file per session, named by the receiving session's id. The alternative
/// is the PTY, and the PTY is where a packet stops being a packet: Claude Code
/// collapses any paste over 800 characters or three lines into
/// `[Pasted text #N]`, and packets are large by design.
///
/// **The directory is swept when it is written to, and at no other time.** It
/// only ever grows on a handoff, so a handoff is the one occasion that can
/// leave it larger than it should be — and nothing here polls, waits or runs on
/// a timer (§19). A file whose session is no longer running is retired then,
/// which covers the session that ended, the one that crashed and the one that
/// ended while the app was closed, without a second signal to subscribe to.
///
/// A file outlives its launch on purpose: a restored pane replays the arguments
/// it was started with, so deleting the file at shutdown would turn a working
/// restart into `Error: Append system prompt file not found`.
class HandoffPacketFiles {
  const HandoffPacketFiles(this.directory);

  final Directory directory;

  /// Writes [packet] as [sessionId]'s brief and returns its path on **this**
  /// filesystem, or `null` when it could not be written.
  ///
  /// [liveSessionIds] is every session whose file must be kept; everything else
  /// in the directory is retired first. Null on failure rather than a throw:
  /// the packet has a second delivery (typed), and a handoff that cannot write
  /// a file must still happen.
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

  /// Deletes [sessionId]'s packet, if it has one. Best-effort, like
  /// `AgentHookInstallationService.retireEndpoints`: a file that will not go is
  /// swept again by the next write.
  bool retire(String sessionId) {
    try {
      final file = File(p.join(directory.path, fileNameFor(sessionId)));
      if (!file.existsSync()) return false;
      file.deleteSync();
      return true;
    } on Object {
      return false;
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

  /// Session ids are UUIDs, so the sanitising changes nothing in practice — but
  /// the id reaches here from a database row, and a file name built from one is
  /// not the place to find out otherwise.
  static String fileNameFor(String sessionId) =>
      'handoff-${sessionId.replaceAll(RegExp('[^A-Za-z0-9-]'), '_')}.md';
}

/// Where handoff packets are written. Overridden in tests with a temp
/// directory; nothing else about the store is faked.
final handoffPacketFilesProvider = FutureProvider<HandoffPacketFiles>((
  ref,
) async {
  final support = await appSupportDirectory();
  return HandoffPacketFiles(Directory(p.join(support.path, 'handoff')));
});
