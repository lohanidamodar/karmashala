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

/// How big the media cache may grow before its least recently used copies go.
const int kMediaCacheLimitBytes = 2 * 1024 * 1024 * 1024;

/// A part file older than this belongs to no copy still running — one writes a
/// chunk a second or so — and is a crashed run's leftover.
const Duration _kStalePart = Duration(days: 1);

/// Thrown by [MediaStore.load] when its `isCancelled` said stop mid-copy: the
/// tab closed, or a newer version of the file superseded this one. The part
/// file is already gone.
class MediaLoadCancelled implements Exception {
  const MediaLoadCancelled();

  @override
  String toString() => 'MediaLoadCancelled';
}

/// Reads one media file through the server, wherever its environment is — the
/// media twin of `DocumentStore`. An image arrives as bytes, under the same
/// size cap the text editor keeps; video and audio are played by media_kit
/// from a path on this machine, so they are handed the file itself where the
/// server's disk is this machine's, and a cached copy where it is not. A
/// single copy has no cap — a film is meant to be big, and it never sits in
/// memory — but the cache as a whole does ([cacheLimitBytes]).
class MediaStore {
  MediaStore(
    this.files, {
    String? cacheDirectory,
    this.cacheLimitBytes = kMediaCacheLimitBytes,
  }) : cacheDirectory =
           cacheDirectory ??
           p.join(Directory.systemTemp.path, 'karmashala', 'media');

  final FilesClient files;

  /// Where remote video and audio are copied to. Copies outlive their tab, so
  /// a reopened file whose version is still cached plays without copying
  /// again; a new version replaces its older ones ([cachePathOf]), and the
  /// whole is held under [cacheLimitBytes], least recently used first out.
  final String cacheDirectory;

  /// The cache's ceiling, checked after every copy lands.
  final int cacheLimitBytes;

  /// What the file looks like now, or null when there is nothing there.
  /// Throws [FilesUnreachableException] when its environment did not answer.
  Future<FileStamp?> stamp(String documentId) async =>
      (await files.stat(documentPathOf(documentId))).stamp;

  /// Never throws but for [FilesUnreachableException]: what went wrong is a
  /// [MediaRefusal] on the document, as `DocumentStore.load` does it. An
  /// environment that did not answer is not a fact about the file, so it is
  /// thrown for the caller to keep whatever it already shows. [onProgress]
  /// hears 0..1 while a remote video or audio file is copied.
  ///
  /// [playsHere] false is a client with no media backend (a phone): video and
  /// audio are stat'ed, never read or copied, and come back with their stamp
  /// and neither bytes nor a local path — there is nothing here to hand them
  /// to. [isCancelled] is asked between chunks of a copy; true stops it,
  /// deletes the part file and throws [MediaLoadCancelled].
  Future<MediaDocument> load(
    String documentId, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
    bool playsHere = true,
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
        return refused(
          MediaRefusal.unreadable,
          '$name is a folder, not a file.',
        );
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
      if (!playsHere) {
        // Copying a film a phone cannot play would spend its data and its
        // storage on nothing; the stamp is enough to tell a change.
        return MediaDocument(hostPath: documentId, kind: kind, stamp: seen);
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
        isCancelled: isCancelled,
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
  ///
  /// Named `<hash(document)>-<hash(version)>.<ext>`: every version of one
  /// document shares the prefix [cachePrefixOf], so a new one landing can find
  /// and drop the ones it replaces.
  String cachePathOf(String documentId, FileStamp? stamp) {
    final version =
        '${stamp?.length}|${stamp?.modified?.toUtc().microsecondsSinceEpoch}';
    final name = documentNameOf(documentId);
    final dot = name.lastIndexOf('.');
    final extension = dot > 0 ? name.substring(dot + 1).toLowerCase() : 'bin';
    return p.join(
      cacheDirectory,
      '${cachePrefixOf(documentId)}${stableMediaHash(version)}.$extension',
    );
  }

  /// The start of every cached version's file name for [documentId].
  String cachePrefixOf(String documentId) => '${stableMediaHash(documentId)}-';

  /// Copies [documentId] to the cache in [kMediaCopyChunkBytes] reads, into a
  /// part file renamed into place only once whole: a copy cut short never
  /// passes for the file. [isCancelled] is asked before every chunk; a copy
  /// nobody wants any more stops there and leaves no part file behind.
  Future<String> _copy(
    String documentId,
    int size,
    FileStamp? stamp, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final target = cachePathOf(documentId, stamp);
    final cached = File(target);
    // A stamp without a modification time cannot tell versions of one length
    // apart, so only a dated one is trusted to the cache.
    if (stamp?.modified != null &&
        cached.existsSync() &&
        cached.lengthSync() == size) {
      // Played again is used again: the cap's eviction goes by this time.
      try {
        cached.setLastModifiedSync(DateTime.now());
      } on FileSystemException {
        // Held open, or read-only: it is only an eviction hint.
      }
      onProgress?.call(1);
      return target;
    }
    if (isCancelled?.call() ?? false) throw const MediaLoadCancelled();
    await Directory(cacheDirectory).create(recursive: true);
    final part = File('$target.${DateTime.now().microsecondsSinceEpoch}.part');
    final at = documentPathOf(documentId);
    final sink = await part.open(mode: FileMode.write);
    var offset = 0;
    try {
      onProgress?.call(0);
      while (true) {
        if (isCancelled?.call() ?? false) throw const MediaLoadCancelled();
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
    _dropOlderVersions(documentId, target);
    _holdUnderLimit(target);
    onProgress?.call(1);
    return target;
  }

  /// The cache's files, or none when it cannot be listed.
  List<File> _cachedFiles() {
    try {
      return Directory(
        cacheDirectory,
      ).listSync(followLinks: false).whereType<File>().toList();
    } on FileSystemException {
      return const [];
    }
  }

  /// Deletes every cached version of [documentId] but [kept]. One media_kit
  /// still plays is held open, and Windows refuses to delete it: that one
  /// stays until the next version lands, or the cap takes it.
  void _dropOlderVersions(String documentId, String kept) {
    final prefix = cachePrefixOf(documentId);
    for (final file in _cachedFiles()) {
      final name = p.basename(file.path);
      if (file.path == kept ||
          !name.startsWith(prefix) ||
          name.endsWith('.part')) {
        continue;
      }
      _deleteQuietly(file);
    }
  }

  /// Evicts the least recently modified copies until the cache is under
  /// [cacheLimitBytes]. Never [kept] — just written, and about to be played —
  /// and never a part file, which is a copy still running; a part file a day
  /// old is no copy's, and goes regardless.
  void _holdUnderLimit(String kept) {
    final now = DateTime.now();
    final sized = <(File, int, DateTime)>[];
    var total = 0;
    for (final file in _cachedFiles()) {
      final stat = file.statSync();
      // A file gone between the listing and the stat says so in its type.
      if (stat.type == FileSystemEntityType.notFound) continue;
      if (file.path.endsWith('.part')) {
        if (now.difference(stat.modified) > _kStalePart) {
          _deleteQuietly(file);
        } else {
          total += stat.size;
        }
        continue;
      }
      total += stat.size;
      if (file.path != kept) sized.add((file, stat.size, stat.modified));
    }
    if (total <= cacheLimitBytes) return;
    sized.sort((a, b) => a.$3.compareTo(b.$3));
    for (final (file, size, _) in sized) {
      if (total <= cacheLimitBytes) break;
      if (_deleteQuietly(file)) total -= size;
    }
  }

  /// Whether [file] went. A file media_kit holds open stays on Windows; the
  /// next copy to land tries again.
  static bool _deleteQuietly(File file) {
    try {
      file.deleteSync();
      return true;
    } on FileSystemException {
      return false;
    }
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
