/// Where a file the phone sends becomes a file on this desktop's disk.
///
/// ## The directory is not a new one
///
/// It is the one the desktop composer already writes to when someone attaches
/// an image there — `<temp>/karmashala/attachments` — because the two are the
/// same act arriving by different doors, and an agent that is handed a path
/// should not be able to tell which door it came through. Temp rather than the
/// application support directory on purpose: unlike the media panel's extracted
/// copies, an attachment only has to outlive the agent's read of it, and a
/// reboot's sweep is a cleanup nobody has to write.
///
/// ## Nothing is a file until a prompt names it
///
/// A [begin] opens a `.part` in `incoming/`, chunks are appended to it, and
/// [commit] is the only thing that ever produces a name an agent is told. So a
/// link that drops mid-upload leaves bytes that nothing points at and nothing
/// will ever quote — see [discard], which is what removes them.
///
/// ## What deletes what, and what does not
///
/// | File | Removed by |
/// | --- | --- |
/// | a `.part` | the same device starting another upload, that device's link
///   ending, and [sweep] at host start |
/// | a committed `phone_*` | [commit] pruning to the newest [keep] |
/// | the composer's own `img_*` | **nothing here** — they are not ours |
///
/// So a desktop that takes 21 attachments and is never touched again keeps
/// twenty of them for ever, or until the OS clears its temp directory. That is
/// stated rather than fixed: at [kMaxAttachmentBytes] each it is a bounded
/// amount, and deleting a file an agent may still be reading would be the
/// worse failure.
library;

import 'dart:io';
import 'dart:math';

import '../domain/remote_payloads.dart';
import '../protocol.dart';

/// How many committed attachments are kept. The newest win, the way
/// `kSessionMediaCap` picks which pictures the media panel keeps.
const int kCompanionAttachmentKeep = 20;

/// The prefix every committed companion attachment carries.
///
/// Load-bearing: it is how the prune tells a file this wrote from the desktop
/// composer's own `img_*` in the same directory, which is not ours to delete.
const String kCompanionAttachmentPrefix = 'phone_';

/// The extension written for each media type a session may accept.
///
/// The host decides the extension, never the phone: a name off a phone is a
/// hint, and an agent that opens a file by path opens it by what the name says
/// it is.
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

  /// Opens an upload for [deviceId], discarding whatever it left half-sent.
  ///
  /// Refuses here — before a byte crosses — for everything that can be known
  /// from the declaration alone. The caller has already checked the request
  /// against the session's own [RemoteAttachmentSupport]; this checks what is
  /// true of any attachment.
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
    // Truncating rather than appending: an id collision is vanishingly
    // unlikely and silently prefixing someone else's bytes is not a failure
    // this should be able to have.
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

  /// Appends one chunk, in order, within the declared length.
  ///
  /// Out of order is refused rather than buffered. The transport drops its
  /// **oldest** queued frame under pressure, so a gap here is evidence a slice
  /// was lost — and a store that silently held chunk 7 waiting for chunk 6
  /// would turn that into a file with a hole in it.
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

  /// Turns [deviceId]'s completed upload into a real file, and answers its
  /// path.
  ///
  /// **The length is checked here**, so a truncated upload can never become
  /// something an agent is told to read. This is also the only place a
  /// committed file is deleted, which keeps growth bounded without a timer.
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
      // A `.part` nothing points at is bytes in a temp directory, not a
      // correctness problem; [sweep] gets it at the next start.
    }
  }

  /// Clears every abandoned `.part` and prunes committed files to [keep].
  ///
  /// Run once as the host starts, which is the one moment there is provably no
  /// upload in flight: an upload is named by a link, and no link has been made
  /// yet. Nothing calls this on a timer.
  Future<void> sweep() async {
    try {
      if (await _incoming.exists()) await _incoming.delete(recursive: true);
    } on Object {
      // Nothing here is load-bearing enough to fail a host start for.
    }
    await _pruneToKeep();
  }

  /// Newest [keep] committed attachments survive; the rest are deleted.
  ///
  /// Only ever files this wrote — the composer's own `img_*` sit in the same
  /// directory and are somebody else's to remove.
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
      // Same: a prune that could not list the directory is not a reason to
      // refuse an attachment that already arrived.
    }
  }

  String _newId() {
    final buffer = StringBuffer();
    for (var i = 0; i < 16; i++) {
      buffer.write(_ids.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  /// A basename the filesystem and the shell can both take, with the host's
  /// own extension on it.
  ///
  /// Everything path-shaped is dropped rather than escaped — a separator, a
  /// `..`, a drive letter — so no name a phone sends can decide where a byte
  /// lands. A name that survives to nothing becomes `attachment`, because a
  /// path an agent cannot pronounce is worse than a generic one.
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
