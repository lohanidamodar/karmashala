import 'dart:convert';
import 'dart:io';

import 'package:karmashala_files/values.dart' show FileStamp;
import 'package:path/path.dart' as p;

import '../../files/data/files_client.dart';
import '../domain/document_id.dart';
import '../domain/media_document.dart';
import '../domain/media_kind.dart';
import '../domain/source_document.dart' show kDocumentSizeLimit;

export '../../files/data/files_client.dart' show FilesUnreachableException;

/// How much of a remote video or audio file one read asks for while it is
/// copied to the cache — the server's own chunk, so every read is one frame.
const int kMediaCopyChunkBytes = 1024 * 1024;

/// Reads one media file through the server, wherever its environment is — the
/// media twin of `DocumentStore`. An image arrives as bytes, under the same
/// size cap the text editor keeps; video and audio are played by media_kit
/// from a path on this machine, so they are handed the file itself where the
/// server's disk is this machine's, and a cached copy where it is not. A copy
/// has no cap: a film is meant to be big, and it never sits in memory.
class MediaStore {
  MediaStore(this.files, {String? cacheDirectory})
    : cacheDirectory =
          cacheDirectory ??
          p.join(Directory.systemTemp.path, 'karmashala', 'media');

  final FilesClient files;

  /// Where remote video and audio are copied to. Copies are left behind on
  /// close: the system's temp sweep is theirs, and a reopened file whose
  /// version is still cached plays without copying again.
  final String cacheDirectory;

  /// What the file looks like now, or null when there is nothing there.
  /// Throws [FilesUnreachableException] when its environment did not answer.
  Future<FileStamp?> stamp(String documentId) async =>
      (await files.stat(documentPathOf(documentId))).stamp;

  /// Never throws but for [FilesUnreachableException]: what went wrong is a
  /// [MediaRefusal] on the document, as `DocumentStore.load` does it. An
  /// environment that did not answer is not a fact about the file, so it is
  /// thrown for the caller to keep whatever it already shows. [onProgress]
  /// hears 0..1 while a remote video or audio file is copied.
  Future<MediaDocument> load(
    String documentId, {
    void Function(double progress)? onProgress,
  }) async {
    final kind = mediaKindOf(documentId);
    final name = documentNameOf(documentId);
    if (kind == null) {
      return MediaDocument(
        hostPath: documentId,
        kind: MediaKind.image,
        refusal: MediaRefusal.unreadable,
        error: '$name is not an image, video or audio file.',
      );
    }
    final at = documentPathOf(documentId);
    FileStamp? seen;
    MediaDocument refused(MediaRefusal refusal, String error) => MediaDocument(
      hostPath: documentId,
      kind: kind,
      stamp: seen,
      refusal: refusal,
      error: error,
    );
    try {
      final stat = await files.stat(at);
      if (!stat.exists) {
        return refused(
          MediaRefusal.notFound,
          '$name was not found at ${at.path}.',
        );
      }
      if (stat.isDirectory) {
        return refused(MediaRefusal.unreadable, '$name is a folder, not a file.');
      }
      seen = stat.stamp;
      if (kind == MediaKind.image) {
        if (stat.size > kDocumentSizeLimit) {
          return refused(
            MediaRefusal.tooLarge,
            '$name is ${describeMediaSize(stat.size)}, over the '
            '${describeMediaSize(kDocumentSizeLimit)} this viewer opens.',
          );
        }
        // `read` with no length walks the file a chunk at a time to its end.
        final bytes = await files.read(at);
        return MediaDocument(
          hostPath: documentId,
          kind: kind,
          stamp: seen,
          bytes: bytes,
        );
      }
      // The server's disk is this machine's: media_kit plays the file where
      // it lies, and a change to it is the change played.
      final local = await files.localPathOf(at);
      if (local != null) {
        return MediaDocument(
          hostPath: documentId,
          kind: kind,
          stamp: seen,
          localPath: local,
        );
      }
      final copied = await _copy(
        documentId,
        stat.size,
        seen,
        onProgress: onProgress,
      );
      return MediaDocument(
        hostPath: documentId,
        kind: kind,
        stamp: seen,
        localPath: copied,
      );
    } on FilesUnreachableException {
      rethrow;
    } on FilesException catch (error) {
      return refused(
        MediaRefusal.unreadable,
        '$name could not be read: ${error.message}',
      );
    } on FileSystemException catch (error) {
      // The cache, not the file: this machine's temp folder refused the copy.
      return refused(
        MediaRefusal.unreadable,
        '$name could not be copied to this machine: ${error.message}',
      );
    }
  }

  /// Where [documentId] at [stamp] is cached. The version is in the name, so a
  /// file changed on disk is copied beside the one media_kit may still hold
  /// open — Windows will not rename over an open file — and a version already
  /// copied is played again without asking for a byte.
  String cachePathOf(String documentId, FileStamp? stamp) {
    final key =
        '$documentId|${stamp?.length}|'
        '${stamp?.modified?.toUtc().microsecondsSinceEpoch}';
    final name = documentNameOf(documentId);
    final dot = name.lastIndexOf('.');
    final extension = dot > 0 ? name.substring(dot + 1).toLowerCase() : 'bin';
    return p.join(cacheDirectory, '${stableMediaHash(key)}.$extension');
  }

  /// Copies [documentId] to the cache in [kMediaCopyChunkBytes] reads, into a
  /// part file renamed into place only once whole: a copy cut short never
  /// passes for the file.
  Future<String> _copy(
    String documentId,
    int size,
    FileStamp? stamp, {
    void Function(double progress)? onProgress,
  }) async {
    final target = cachePathOf(documentId, stamp);
    final cached = File(target);
    // A stamp without a modification time cannot tell versions of one length
    // apart, so only a dated one is trusted to the cache.
    if (stamp?.modified != null &&
        cached.existsSync() &&
        cached.lengthSync() == size) {
      onProgress?.call(1);
      return target;
    }
    await Directory(cacheDirectory).create(recursive: true);
    final part = File('$target.${DateTime.now().microsecondsSinceEpoch}.part');
    final at = documentPathOf(documentId);
    final sink = await part.open(mode: FileMode.write);
    var offset = 0;
    try {
      onProgress?.call(0);
      while (true) {
        final chunk = await files.read(
          at,
          offset: offset,
          length: kMediaCopyChunkBytes,
        );
        if (chunk.isEmpty) break;
        await sink.writeFrom(chunk);
        offset += chunk.length;
        if (size > 0) onProgress?.call((offset / size).clamp(0.0, 1.0));
        // A file that grew while it was copied is copied as it was stamped;
        // the watch that saw it grow asks for the rest.
        if (offset >= size) break;
      }
      await sink.close();
    } on Object {
      await _quietly(sink.close);
      await _quietly(part.delete);
      rethrow;
    }
    try {
      await part.rename(target);
    } on FileSystemException {
      // Something already there — a copy another load finished first. Ours is
      // the same version, so whichever landed is the file.
      await _quietly(part.delete);
      if (!cached.existsSync()) rethrow;
    }
    onProgress?.call(1);
    return target;
  }

  static Future<void> _quietly(Future<Object?> Function() step) async {
    try {
      await step();
    } on Object {
      // Cleanup of a part file is best effort; the temp sweep has the rest.
    }
  }
}

/// A 64-bit FNV-1a of [key], in hex — stable across runs and machines, which
/// `String.hashCode` is not promised to be.
String stableMediaHash(String key) {
  var hash = -3750763034362895579; // 0xcbf29ce484222325, the FNV offset basis.
  for (final byte in utf8.encode(key)) {
    hash ^= byte;
    hash *= 0x100000001b3;
  }
  return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
}

/// [bytes] the way the size refusal says it.
String describeMediaSize(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
  return '$bytes bytes';
}
