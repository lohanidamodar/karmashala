import 'document_id.dart';

/// What a media file is, as far as the viewer cares: it decides which view an
/// editor tab shows instead of text.
enum MediaKind { image, video, audio }

const Map<String, MediaKind> _byExtension = {
  'png': MediaKind.image,
  'jpg': MediaKind.image,
  'jpeg': MediaKind.image,
  'gif': MediaKind.image,
  'webp': MediaKind.image,
  'bmp': MediaKind.image,
  'ico': MediaKind.image,
  'mp4': MediaKind.video,
  'webm': MediaKind.video,
  'mov': MediaKind.video,
  'mkv': MediaKind.video,
  'mp3': MediaKind.audio,
  'wav': MediaKind.audio,
  'ogg': MediaKind.audio,
  'm4a': MediaKind.audio,
  'flac': MediaKind.audio,
};

/// The media kind of [documentId] by its extension, or null for a file the
/// text editor opens. SVG is text on purpose: its source is what gets edited.
MediaKind? mediaKindOf(String documentId) {
  final name = documentNameOf(documentId);
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return null;
  return _byExtension[name.substring(dot + 1).toLowerCase()];
}
