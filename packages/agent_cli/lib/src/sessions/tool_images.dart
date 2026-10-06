import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'tool_activity.dart';

/// Where [spillToolImage] keeps the images tools answered with: the data
/// folder's `tool-images` once a process names it, so a probe keeps its own.
Directory get toolImageDirectory => _toolImageDirectory;

Directory _toolImageDirectory = legacyToolImageDirectory;

/// Where the cache was before it moved under the data folder.
Directory get legacyToolImageDirectory => Directory(
  p.join(Directory.systemTemp.path, 'karmashala', kToolImageFolderName),
);

void useToolImageDirectory(String path) =>
    _toolImageDirectory = Directory(path);

/// The cache folder's name, under whichever data folder holds it.
const String kToolImageFolderName = 'tool-images';

/// A cached image nobody has read for this long is dropped.
const Duration kToolImageMaxAge = Duration(days: 14);

/// The most the cache may hold; past it the least recently used go first.
const int kToolImageMaxBytes = 256 * 1024 * 1024;

/// Drops images unused for [maxAge], then the least recently used until the
/// folder holds [maxBytes] or less. Returns how many files went.
int sweepToolImages(
  Directory directory, {
  Duration maxAge = kToolImageMaxAge,
  int maxBytes = kToolImageMaxBytes,
  DateTime? now,
}) {
  final cutoff = (now ?? DateTime.now()).subtract(maxAge);
  final kept = <(File, DateTime, int)>[];
  var swept = 0;
  bool drop(File file) {
    try {
      file.deleteSync();
      swept++;
      return true;
    } on FileSystemException {
      // Held open by a viewer; the next sweep takes it.
      return false;
    }
  }

  try {
    for (final entry in directory.listSync(followLinks: false)) {
      if (entry is! File) continue;
      final stat = entry.statSync();
      if (!stat.modified.isBefore(cutoff) || !drop(entry)) {
        kept.add((entry, stat.modified, stat.size));
      }
    }
  } on FileSystemException {
    return swept;
  }
  var total = kept.fold<int>(0, (sum, file) => sum + file.$3);
  kept.sort((a, b) => a.$2.compareTo(b.$2));
  for (final (file, _, size) in kept) {
    if (total <= maxBytes) break;
    if (drop(file)) total -= size;
  }
  return swept;
}

/// What a row says when its image file is gone: a cached tool image was
/// swept, any other was moved or deleted by somebody.
String missingImageNote(String path) => _isCachedToolImage(path)
    ? 'That image is no longer kept.'
    : 'That image is no longer on disk.';

bool _isCachedToolImage(String path) {
  final parts = path.split(RegExp(r'[\\/]'));
  return parts.length >= 2 &&
      parts[parts.length - 2] == kToolImageFolderName &&
      _cachedName.hasMatch(parts.last);
}

final RegExp _cachedName = RegExp(r'^[0-9a-f]+-\d+\.[a-z]+$');

/// The most base64 one image may be: past it, a row says nothing of it.
const int kMaxToolImageBase64 = 16 * 1024 * 1024;

/// A file holding the image [base64Data] decodes to, written once and named
/// by its content, or null when it is not one we can draw.
///
/// A row carries this path rather than the bytes: a screenshot is ~280 KB
/// of base64 here and a session may hold a hundred, re-read on every poll.
String? spillToolImage(String base64Data, {String? mimeType}) {
  final extension = _extensions[mimeType?.toLowerCase()];
  if (extension == null || base64Data.length > kMaxToolImageBase64) {
    return null;
  }
  final List<int> bytes;
  try {
    bytes = base64Decode(base64Data.trim());
  } on FormatException {
    return null;
  }
  if (bytes.isEmpty) return null;
  final file = File(
    p.join(
      toolImageDirectory.path,
      '${_fnv1a(base64Data)}-${base64Data.length}.$extension',
    ),
  );
  try {
    final stat = file.statSync();
    if (stat.type == FileSystemEntityType.notFound) {
      file.parent.createSync(recursive: true);
      // Renamed into place, so a reader never draws half a file.
      final partial = File('${file.path}.$pid.part')..writeAsBytesSync(bytes);
      partial.renameSync(file.path);
    } else if (DateTime.now().difference(stat.modified).inDays >= 1) {
      // Read again: the sweep counts it as used.
      file.setLastModifiedSync(DateTime.now());
    }
  } on FileSystemException {
    return null;
  }
  return file.path;
}

/// [spillToolImage] for a `data:<mime>;base64,<data>` URL.
String? spillToolImageUrl(Object? url) {
  if (url is! String) return null;
  final match = _dataUrl.firstMatch(url);
  if (match == null) return null;
  return spillToolImage(url.substring(match.end), mimeType: match[1]);
}

final RegExp _dataUrl = RegExp(r'^data:([\w/+.-]+);base64,');

/// Only types [kPreviewableImageExtensions] can draw.
const Map<String?, String> _extensions = {
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'image/jpg': 'jpg',
  'image/gif': 'gif',
  'image/webp': 'webp',
  'image/bmp': 'bmp',
};

String _fnv1a(String text) {
  var hash = 0xcbf29ce484222325;
  for (var i = 0; i < text.length; i++) {
    hash ^= text.codeUnitAt(i);
    hash *= 0x100000001b3;
  }
  return hash.toUnsigned(64).toRadixString(16);
}
