import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../domain/verification_artifact.dart';

/// Where a run's evidence is written: one directory per run, and the only
/// place that knows the layout — the database stores paths relative to it, so
/// the folder can be zipped with its image links intact.
class VerificationArtifactStore {
  VerificationArtifactStore(this.root);

  /// The parent of every run directory.
  final Directory root;

  Directory directoryFor(String runId) => Directory(p.join(root.path, runId));

  Future<Directory> createDirectory(String runId) async {
    final dir = directoryFor(runId);
    await dir.create(recursive: true);
    return dir;
  }

  /// Writes [bytes] into the run's directory; [name] carries no extension.
  Future<VerificationArtifact> write({
    required String runId,
    required VerificationArtifactKind kind,
    required String label,
    required String name,
    required List<int> bytes,
    int? stepOrdinal,
    DateTime? at,
    bool overwrite = false,
  }) async {
    final dir = await createDirectory(runId);
    final wanted = '${_slug(name)}.${kind.extension}';
    final fileName = overwrite ? wanted : _uniqueName(dir, wanted);
    final file = File(p.join(dir.path, fileName));
    await file.writeAsBytes(bytes, flush: true);
    return VerificationArtifact(
      id: '$runId:$fileName',
      runId: runId,
      kind: kind,
      label: label,
      relativePath: fileName,
      byteSize: bytes.length,
      at: (at ?? DateTime.now()).toUtc(),
      stepOrdinal: stepOrdinal,
    );
  }

  Future<VerificationArtifact> writeText({
    required String runId,
    required VerificationArtifactKind kind,
    required String label,
    required String name,
    required String text,
    int? stepOrdinal,
    DateTime? at,
    bool overwrite = false,
  }) => write(
    runId: runId,
    kind: kind,
    label: label,
    name: name,
    bytes: utf8.encode(text),
    stepOrdinal: stepOrdinal,
    at: at,
    overwrite: overwrite,
  );

  /// The bytes of an artifact, or null when the file has gone — a normal
  /// outcome that must not take a pane or a tool call down with it.
  Future<Uint8List?> read(VerificationArtifact artifact) async {
    final file = File(
      p.join(directoryFor(artifact.runId).path, artifact.relativePath),
    );
    if (!file.existsSync()) return null;
    return file.readAsBytes();
  }

  String pathOf(VerificationArtifact artifact) =>
      p.join(directoryFor(artifact.runId).path, artifact.relativePath);

  /// Removes a run's directory. Best effort: a held-open file must not stop
  /// the database row from going away.
  Future<void> deleteRun(String runId) async {
    final dir = directoryFor(runId);
    if (!dir.existsSync()) return;
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // Left on disk; the row is gone, and the folder is inert.
    }
  }

  /// A file name that does not collide with one already in the directory.
  static String _uniqueName(Directory dir, String preferred) {
    if (!File(p.join(dir.path, preferred)).existsSync()) return preferred;
    final ext = p.extension(preferred);
    final base = p.basenameWithoutExtension(preferred);
    for (var i = 2; i < 1000; i++) {
      final candidate = '$base-$i$ext';
      if (!File(p.join(dir.path, candidate)).existsSync()) return candidate;
    }
    return '$base-${DateTime.now().microsecondsSinceEpoch}$ext';
  }

  /// A file name safe on Windows: no separators, no reserved names, non-empty.
  static String _slug(String value) {
    final cleaned = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    if (cleaned.isEmpty) return 'artifact';
    return cleaned.length <= 60 ? cleaned : cleaned.substring(0, 60);
  }
}
