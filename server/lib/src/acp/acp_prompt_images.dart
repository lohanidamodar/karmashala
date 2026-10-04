import 'dart:convert';
import 'dart:io';

import 'package:karmashala_acp/karmashala_acp.dart' show ImageContent;
import 'package:path/path.dart' as p;

/// The heading the desktop composer and the companion put over the paths of
/// the images a message carries, one path per line, on this server's disk.
const String kAttachedImagesHeading = 'Attached image(s):';

/// The most of one image sent inline; a larger one stays a path.
const int kMaxPromptImageBytes = 5 * 1024 * 1024;

const _imageTypes = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
};

/// A message's [kAttachedImagesHeading] block, read off it.
class AttachedImages {
  AttachedImages._(this._text, this._lines, this._at, this._end, this.paths);

  final String _text;
  final List<String> _lines;
  final int _at;
  final int _end;

  /// The image paths, in the order given; empty when there is no block.
  final List<String> paths;

  /// The message with [sent] gone from the block, and the block gone with
  /// them when nothing is left of it.
  String textWithout(Set<String> sent) {
    if (_at < 0) return _text;
    final kept = [
      for (final path in paths)
        if (!sent.contains(path)) path,
    ];
    final parts = [
      _trimBlank(_lines.sublist(0, _at)).join('\n'),
      if (kept.isNotEmpty) [kAttachedImagesHeading, ...kept].join('\n'),
      _trimBlank(_lines.sublist(_end)).join('\n'),
    ];
    return parts.where((part) => part.isNotEmpty).join('\n\n');
  }

  static List<String> _trimBlank(List<String> lines) {
    var start = 0;
    var end = lines.length;
    while (start < end && lines[start].trim().isEmpty) {
      start++;
    }
    while (end > start && lines[end - 1].trim().isEmpty) {
      end--;
    }
    return lines.sublist(start, end);
  }
}

AttachedImages splitAttachedImages(String text) {
  final lines = text.split('\n');
  final at = lines.indexWhere((l) => l.trim() == kAttachedImagesHeading);
  if (at < 0) return AttachedImages._(text, lines, -1, -1, const []);
  var end = at + 1;
  while (end < lines.length && lines[end].trim().isNotEmpty) {
    end++;
  }
  return AttachedImages._(text, lines, at, end, [
    for (final line in lines.sublist(at + 1, end)) line.trim(),
  ]);
}

/// [path] as an image block, or why it cannot be one, in words.
({ImageContent? image, String? refusal}) promptImage(String path) {
  final type = _imageTypes[p.extension(path).toLowerCase()];
  if (type == null) return (image: null, refusal: 'not a PNG, JPEG, GIF or WebP');
  try {
    final file = File(path);
    final size = file.lengthSync();
    if (size > kMaxPromptImageBytes) {
      return (
        image: null,
        refusal: 'larger than ${kMaxPromptImageBytes ~/ (1024 * 1024)} MB',
      );
    }
    final bytes = file.readAsBytesSync();
    return (
      image: ImageContent(data: base64Encode(bytes), mimeType: type),
      refusal: null,
    );
  } on FileSystemException catch (error) {
    return (
      image: null,
      refusal: 'it could not be read: ${error.osError?.message ?? error.message}',
    );
  }
}
