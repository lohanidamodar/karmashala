import 'dart:io';
import 'dart:typed_data';

import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:agent_cli/stream.dart'
    show looksLikeImagePath, missingImageNote;

import '../domain/file_preview_kind.dart';
import '../domain/image_dimensions.dart';
import 'file_preview_loader.dart';

/// What reading one picture for the chat came to: its bytes, or the words
/// that follow its name when there are none ("is no longer on disk").
class TranscriptImageRead {
  TranscriptImageRead.loaded(Uint8List this.bytes, {required int this.size})
    : dimensions = imageDimensions(bytes),
      note = null,
      gone = false;

  const TranscriptImageRead.failed(String this.note, {this.gone = false})
    : bytes = null,
      size = null,
      dimensions = null;

  final Uint8List? bytes;
  final int? size;

  /// From the picture's header; null for an SVG or a header not understood.
  final ({int width, int height})? dimensions;

  final String? note;

  /// The file is not there any more, as opposed to unreadable.
  final bool gone;
}

/// Brings a picture a server elsewhere holds to a file this machine can read.
/// Throws an [Exception] whose text is the sentence to show when it cannot.
typedef TranscriptImageFileFetch = Future<File> Function(String path);

/// [path] names a picture the chat can draw.
bool isTranscriptPicture(String path) =>
    looksLikeImagePath(path) || path.toLowerCase().endsWith('.svg');

/// The note for a picture that is gone: "is no longer on disk", or "is no
/// longer kept" for a swept tool image.
String goneImageNote(String path) => _phrase(missingImageNote(path));

String tooLargeImageNote(int size) =>
    'is too large to preview (${formatFileSize(size)})';

const kUnplacedImageNote =
    'cannot be shown: there is no record of where this session runs';

const kUnreadImageNote = 'could not be read';

/// "That image is no longer on disk." as the words after a name.
String _phrase(String sentence) {
  const lead = 'That image ';
  if (!sentence.startsWith(lead)) return 'could not be opened: $sentence';
  final rest = sentence.substring(lead.length);
  return rest.endsWith('.') ? rest.substring(0, rest.length - 1) : rest;
}

/// Reads [path] through the server, wherever it is: this machine, a WSL
/// distribution or an SSH host.
Future<TranscriptImageRead> readImageThroughServer(
  FilePreviewLoader loader,
  EnvironmentPath path,
) async {
  final FilePreviewData data;
  try {
    data = await loader.load(path);
  } catch (_) {
    // The server could not reach it: a stopped distribution, a host offline.
    return const TranscriptImageRead.failed(kUnreadImageNote);
  }
  if (data.missing) {
    return TranscriptImageRead.failed(goneImageNote(path.path), gone: true);
  }
  if (data.tooLarge) {
    return TranscriptImageRead.failed(tooLargeImageNote(data.size));
  }
  final bytes = data.bytes;
  if (bytes == null || data.directory) {
    return const TranscriptImageRead.failed('has no preview');
  }
  return TranscriptImageRead.loaded(bytes, size: data.size);
}

/// Brings [path] from a server elsewhere with [fetch], then reads the copy.
Future<TranscriptImageRead> readFetchedImage(
  TranscriptImageFileFetch fetch,
  String path, {
  required int maxBytes,
}) async {
  if (!isTranscriptPicture(path)) {
    return const TranscriptImageRead.failed('is not an image');
  }
  final File file;
  try {
    file = await fetch(path);
  } on Exception catch (error) {
    final said = '$error';
    return TranscriptImageRead.failed(
      _phrase(said),
      gone: said == missingImageNote(path),
    );
  } catch (_) {
    return const TranscriptImageRead.failed('could not be opened');
  }
  return readImageFile(file, path, maxBytes: maxBytes);
}

/// Reads [path] from this disk, translated by [resolveHostPath] when the
/// agent wrote it in another environment's spelling.
Future<TranscriptImageRead> readImageFromDisk(
  String path, {
  String? Function(String path)? resolveHostPath,
  required int maxBytes,
}) {
  var host = path;
  if (resolveHostPath != null) {
    try {
      host = resolveHostPath(path) ?? path;
    } catch (_) {
      // A translator that throws is a translator that could not answer.
    }
  }
  if (!isTranscriptPicture(host)) {
    return Future.value(const TranscriptImageRead.failed('is not an image'));
  }
  return readImageFile(File(host), path, maxBytes: maxBytes);
}

/// Reads [file], refusing one past [maxBytes]: a decode allocates
/// `width * height * 4` bytes whatever the file weighs. [path] is how the
/// conversation wrote it, for the note.
Future<TranscriptImageRead> readImageFile(
  File file,
  String path, {
  required int maxBytes,
}) async {
  try {
    final stat = await file.stat();
    if (stat.type == FileSystemEntityType.notFound) {
      return TranscriptImageRead.failed(goneImageNote(path), gone: true);
    }
    if (stat.size > maxBytes) {
      return TranscriptImageRead.failed(tooLargeImageNote(stat.size));
    }
    final bytes = await file.readAsBytes();
    return TranscriptImageRead.loaded(bytes, size: bytes.length);
  } catch (_) {
    // A locked file, a share that went away, a path this platform rejects.
    return const TranscriptImageRead.failed('could not be opened');
  }
}
