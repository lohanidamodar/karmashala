import 'dart:io';
import 'dart:isolate';

import 'package:agent_cli/descriptors.dart' show AgentRegistry;
import 'package:agent_cli/read.dart' show SessionMediaScan, SessionMediaStore;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/transcript.dart' show ChatViewEvidence;
import 'package:path/path.dart' as p;

import 'session_records.dart';

/// **A session's pictures, extracted here for any client** (Stage 0 step 10):
/// the app's own [SessionMediaStore], run over the record [lookUp] finds, into
/// `<data dir>/media/<sessionId>/`. That folder is a cache the record can
/// always rebuild, so only the [keptSessions] most recently read are kept.
class SessionMedia {
  SessionMedia({
    required this.lookUp,
    required this.registry,
    required this.root,
    this.keptSessions = 64,
  });

  final Future<SessionRecordLookup> Function(String sessionId) lookUp;
  final AgentRegistry registry;

  /// `<data dir>/media`.
  final String root;
  final int keptSessions;

  /// The last scan per session, so an unchanged record costs a `stat()`.
  final _scans = <String, SessionMediaScan>{};
  static const int _heldScans = 16;

  /// One scan per session at a time; a second asker shares it.
  final _running = <String, Future<SessionMediaScan>>{};

  Future<SessionMediaListing> list(SessionMediaRead request) async {
    final sessionId = request.sessionId;
    final found = await lookUp(sessionId);
    final path = found.path;
    final agentId = found.agentId;
    if (path == null || agentId == null) {
      return SessionMediaListing(
        absence: found.absence ?? ChatViewEvidence.notLocated,
      );
    }
    final scan = await (_running[sessionId] ??= _scan(
      sessionId,
      path,
      agentId,
    ).whenComplete(() => _running.remove(sessionId)));
    final stamp = '${scan.transcriptPath}|${scan.scannedBytes}';
    if (request.known == stamp) {
      return SessionMediaListing(stamp: stamp, unchanged: true);
    }
    return SessionMediaListing(items: scan.newestFirst, stamp: stamp);
  }

  Future<SessionMediaScan> _scan(
    String sessionId,
    String path,
    String agentId,
  ) async {
    final folder = Directory(p.join(root, _folderName(sessionId)));
    final previous = _scans.remove(sessionId);
    if (previous == null) await _admit(folder);
    final SessionMediaScan scan;
    if (await _grew(path, previous) &&
        identical(registry, AgentRegistry.builtIn) &&
        registry.adapterFor(agentId)?.media != null) {
      scan = await _refreshOffThread(folder.path, path, agentId, previous);
    } else {
      scan = await SessionMediaStore(
        folder,
        registry: registry,
      ).refresh(path, agentId, previous: previous);
    }
    _scans[sessionId] = scan;
    while (_scans.length > _heldScans) {
      _scans.remove(_scans.keys.first);
    }
    return scan;
  }

  /// Whether [path] holds more than [previous] scanned, so a scan has work.
  static Future<bool> _grew(String path, SessionMediaScan? previous) async {
    if (previous == null || previous.transcriptPath != path) return true;
    try {
      return (await File(path).stat()).size != previous.scannedBytes;
    } on Object {
      return false;
    }
  }

  /// The scan on a worker: a large pasted picture is decoded and written
  /// there, not on the isolate serving every client. Only paths and plain
  /// values cross; the worker finds the reader in [AgentRegistry.builtIn].
  static Future<SessionMediaScan> _refreshOffThread(
    String folder,
    String path,
    String agentId,
    SessionMediaScan? previous,
  ) => Isolate.run(
    () => SessionMediaStore(
      Directory(folder),
    ).refresh(path, agentId, previous: previous),
  );

  /// Marks [folder] as read now and drops the least recently read beyond
  /// [keptSessions].
  Future<void> _admit(Directory folder) async {
    try {
      await folder.create(recursive: true);
      final marker = File(p.join(folder.path, _usedMarker));
      await marker.writeAsString('');
      await marker.setLastModified(DateTime.now());
      final folders = <(Directory, DateTime)>[];
      await for (final entry in Directory(root).list()) {
        if (entry is! Directory) continue;
        final used = await File(p.join(entry.path, _usedMarker)).stat();
        folders.add((
          entry,
          used.type == FileSystemEntityType.notFound
              ? (await entry.stat()).modified
              : used.modified,
        ));
      }
      if (folders.length <= keptSessions) return;
      folders.sort((a, b) => a.$2.compareTo(b.$2));
      for (final (dropped, _) in folders.take(folders.length - keptSessions)) {
        if (p.equals(dropped.path, folder.path)) continue;
        _scans.removeWhere(
          (id, _) => _folderName(id) == p.basename(dropped.path),
        );
        await dropped.delete(recursive: true);
      }
    } on FileSystemException {
      // A cache that cannot be trimmed still answers; the next read retries.
    }
  }

  static const String _usedMarker = '.used';

  static String _folderName(String sessionId) {
    final safe = sessionId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return safe.isEmpty ? '_' : safe;
  }
}
