import 'dart:typed_data';

import 'package:karmashala_files/values.dart' show FileStamp;

import 'document_id.dart';
import 'media_kind.dart';

/// Why a media file is not shown, or [none].
enum MediaRefusal { none, notFound, unreadable, tooLarge }

/// One open media file. An image carries its [bytes]; video and audio carry a
/// [localPath] media_kit can play — the file itself when the server's disk is
/// this machine's, otherwise a copy in the client's media cache.
class MediaDocument {
  const MediaDocument({
    required this.hostPath,
    required this.kind,
    this.stamp,
    this.bytes,
    this.localPath,
    this.copyProgress,
    this.refusal = MediaRefusal.none,
    this.error,
    this.revision = 0,
  });

  /// The document id (`document_id.dart`).
  final String hostPath;
  final MediaKind kind;

  /// What was on disk when it was read; null until then.
  final FileStamp? stamp;

  /// An image's bytes.
  final Uint8List? bytes;

  /// Where video or audio plays from.
  final String? localPath;

  /// 0..1 while a remote video or audio file is copied to the cache; null
  /// otherwise.
  final double? copyProgress;

  final MediaRefusal refusal;

  /// What to tell the reader when [refusal] is not [MediaRefusal.none], or the
  /// server was unreachable on the last reload (the last content is kept).
  final String? error;

  /// Bumped on every reload from disk, so a view can tell a refreshed file
  /// from a rebuild.
  final int revision;

  String get name => documentNameOf(hostPath);

  bool get isReady =>
      refusal == MediaRefusal.none &&
      (kind == MediaKind.image ? bytes != null : localPath != null);

  MediaDocument copyWith({
    FileStamp? stamp,
    Uint8List? bytes,
    String? localPath,
    double? copyProgress,
    bool clearCopyProgress = false,
    MediaRefusal? refusal,
    String? error,
    bool clearError = false,
    int? revision,
  }) => MediaDocument(
    hostPath: hostPath,
    kind: kind,
    stamp: stamp ?? this.stamp,
    bytes: bytes ?? this.bytes,
    localPath: localPath ?? this.localPath,
    copyProgress: clearCopyProgress
        ? null
        : (copyProgress ?? this.copyProgress),
    refusal: refusal ?? this.refusal,
    error: clearError ? null : (error ?? this.error),
    revision: revision ?? this.revision,
  );
}
