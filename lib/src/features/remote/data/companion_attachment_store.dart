/// Where a file the phone sends becomes a file on this disk. Nothing is a file
/// until [commit] names it; a dropped link leaves a `.part` nothing points at.
library;

import 'dart:io';
import 'dart:math';

import 'package:karmashala_remote/remote.dart';

/// How many committed attachments are kept; the newest win.
const int kCompanionAttachmentKeep = 20;

/// The prefix every committed attachment carries: how the prune tells a file
/// this wrote from the composer's own `img_*`, which is not ours to delete.
const String kCompanionAttachmentPrefix = 'phone_';

/// The extension for each media type. The host decides it, never the phone: an
/// agent opens a file by what the name says it is.
const Map<String, String> kAttachmentExtensions = {
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'image/gif': 'gif',
  'image/webp': 'webp',
};

/// An upload that cannot be continued, in words the wire can carry.
class AttachmentUploadException implements Exception {
  const AttachmentUploadException(this.message);

  /// Never quotes the file's contents, and never its full path.
  final String message;

  @override
  String toString() => 'AttachmentUploadException: $message';
}

/// One device's upload in flight.
class _Upload {
  _Upload({
    required this.id,
    required this.file,
    required this.declaredBytes,
    required this.safeName,
  });

  final String id;
  final File file;
  final int declaredBytes;
  final String safeName;

  /// The chunk index expected next. A gap is refused rather than padded.
  int nextSeq = 0;
  int written = 0;
}

/// Stages a phone's bytes, then commits them under a name an agent can open.
class CompanionAttachmentStore {
  CompanionAttachmentStore(this.root, {this.keep = kCompanionAttachmentKeep});

  /// `<temp>/karmashala/attachments` in production — the directory the desktop
  /// composer already uses.
  final Directory root;

  /// How many committed attachments survive a [commit].
  final int keep;

  /// At most one upload per device: a phone sends a file and then the prompt
  /// that quotes it, so a second [begin] means the first was abandoned.
  final Map<String, _Upload> _inFlight = {};

  final Random _ids = Random.secure();

  Directory get _incoming => Directory('${root.path}/incoming');

  /// Opens an upload for [deviceId], dropping whatever it left half-sent, and
  /// refuses before a byte crosses whatever the declaration alone can settle.
  Future<RemoteAttachmentOffer> begin(
    String deviceId,
    RemoteAttachmentBegin request,
  ) async {
    if (request.bytes < 1 || request.bytes > kMaxAttachmentBytes) {
      throw AttachmentUploadException(
        'an attachment must be between 1 byte and '
        '${kMaxAttachmentBytes ~/ (1024 * 1024)} MB',
      );
    }
    final extension = kAttachmentExtensions[request.mediaType];
    if (extension == null) {
      throw AttachmentUploadException(
        'this desktop cannot write a ${request.mediaType} attachment',
      );
    }
    await discard(deviceId);
    final id = _newId();
    await _incoming.create(recursive: true);
    final file = File('${_incoming.path}/${deviceId}_$id.part');
    // Truncating rather than appending: silently prefixing someone else's bytes
    // after an id collision is not a failure this should be able to have.
    await file.writeAsBytes(const [], flush: true);
    _inFlight[deviceId] = _Upload(
      id: id,
      file: file,
      declaredBytes: request.bytes,
      safeName: _safeName(request.name, extension),
    );
    return RemoteAttachmentOffer(
      uploadId: id,
      chunkBytes: kAttachmentChunkBytes,
    );
  }

  /// Appends one chunk, in order. Out of order is refused, not buffered: the
  /// transport drops its oldest queued frame, so a gap means a slice was lost.
  Future<void> write(
    String deviceId,
    String uploadId,
    int seq,
    List<int> data,
  ) async {
    final upload = _inFlight[deviceId];
    if (upload == null || upload.id != uploadId) {
      throw const AttachmentUploadException(
        'no attachment is being sent — start one first',
      );
    }
    if (seq != upload.nextSeq) {
      throw AttachmentUploadException(
        'expected chunk ${upload.nextSeq}, got $seq — a slice was lost',
      );
    }
    if (data.isEmpty || data.length > kAttachmentChunkBytes) {
      throw AttachmentUploadException(
        'a chunk carries 1 to $kAttachmentChunkBytes bytes',
      );
    }
    if (upload.written + data.length > upload.declaredBytes) {
      throw const AttachmentUploadException(
        'this attachment is longer than it said it was',
      );
    }
    await upload.file.writeAsBytes(data, mode: FileMode.append, flush: true);
    upload.written += data.length;
    upload.nextSeq++;
  }

  /// Turns a completed upload into a real file. **The length is checked here**,
  /// so a truncated upload never becomes a path an agent is given.
  Future<File> commit(String deviceId, String uploadId) async {
    final upload = _inFlight[deviceId];
    if (upload == null || upload.id != uploadId) {
      throw const AttachmentUploadException(
        'that attachment is not waiting to be sent',
      );
    }
    if (upload.written != upload.declaredBytes) {
      await discard(deviceId);
      throw AttachmentUploadException(
        'only ${upload.written} of ${upload.declaredBytes} bytes arrived',
      );
    }
    _inFlight.remove(deviceId);
    await root.create(recursive: true);
    final committed = File(
      '${root.path}/$kCompanionAttachmentPrefix${upload.id}_${upload.safeName}',
    );
    await upload.file.rename(committed.path);
    await _pruneToKeep();
    return committed;
  }

  /// Drops whatever [deviceId] left half-sent. Safe to call when there is
  /// nothing.
  Future<void> discard(String deviceId) async {
    final upload = _inFlight.remove(deviceId);
    if (upload == null) return;
    try {
      if (await upload.file.exists()) await upload.file.delete();
    } on Object {
      // A `.part` nothing points at is bytes in a temp directory; [sweep] gets
      // it at the next start.
    }
  }

  /// Clears every abandoned `.part` and prunes to [keep]. Run once as the host
  /// starts — the one moment there is provably no upload in flight.
  Future<void> sweep() async {
    try {
      if (await _incoming.exists()) await _incoming.delete(recursive: true);
    } on Object {
      // Nothing here is load-bearing enough to fail a host start for.
    }
    await _pruneToKeep();
  }

  /// Newest [keep] committed attachments survive. Only ever files this wrote:
  /// the composer's own `img_*` share the directory and are not ours.
  Future<void> _pruneToKeep() async {
    try {
      if (!await root.exists()) return;
      final ours = <({File file, DateTime at})>[];
      await for (final entry in root.list(followLinks: false)) {
        if (entry is! File) continue;
        final name = entry.uri.pathSegments.last;
        if (!name.startsWith(kCompanionAttachmentPrefix)) continue;
        ours.add((file: entry, at: await entry.lastModified()));
      }
      if (ours.length <= keep) return;
      ours.sort((a, b) => b.at.compareTo(a.at));
      for (final stale in ours.sublist(keep)) {
        try {
          await stale.file.delete();
        } on Object {
          // Left behind rather than failing the send it is cleaning up after.
        }
      }
    } on Object {
      // Same: a prune that could not list the directory is no reason to refuse
      // an attachment that already arrived.
    }
  }

  String _newId() {
    final buffer = StringBuffer();
    for (var i = 0; i < 16; i++) {
      buffer.write(_ids.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  /// A basename the filesystem and the shell can both take. Path-shaped parts
  /// are dropped, not escaped, so no name a phone sends picks the place.
  static String _safeName(String name, String extension) {
    final base = name.split(RegExp(r'[\\/]')).last;
    final stem = base.contains('.')
        ? base.substring(0, base.lastIndexOf('.'))
        : base;
    var safe = stem.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    safe = safe.replaceAll(RegExp(r'^[._-]+'), '');
    if (safe.length > 48) safe = safe.substring(0, 48);
    if (safe.isEmpty) safe = 'attachment';
    return '$safe.$extension';
  }
}
