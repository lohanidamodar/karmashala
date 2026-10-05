import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'tool_activity.dart';

/// Where [spillToolImage] keeps the images tools answered with.
Directory get toolImageDirectory =>
    Directory(p.join(Directory.systemTemp.path, 'karmashala', 'tool-images'));

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
    if (!file.existsSync()) {
      file.parent.createSync(recursive: true);
      // Renamed into place, so a reader never draws half a file.
      final partial = File('${file.path}.$pid.part')..writeAsBytesSync(bytes);
      partial.renameSync(file.path);
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
