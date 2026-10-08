import 'dart:io';
import 'dart:isolate';

import 'package:file_selector/file_selector.dart' show getSaveLocation;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:pasteboard/pasteboard.dart';

/// This device's clipboard for pictures. A seam, so a test can watch a copy.
class ImageClipboard {
  const ImageClipboard();

  /// pasteboard writes a picture on Windows, macOS, iOS and Android; Linux
  /// goes through `wl-copy` or `xclip`, which may not be installed.
  bool get supported =>
      !kIsWeb &&
      (Platform.isWindows ||
          Platform.isMacOS ||
          Platform.isIOS ||
          Platform.isAndroid ||
          Platform.isLinux);

  Future<void> writePng(Uint8List png) =>
      !kIsWeb && Platform.isLinux ? _linux(png) : Pasteboard.writeImage(png);

  /// pasteboard 0.5's Linux writeImage does nothing.
  static Future<void> _linux(Uint8List png) async {
    final wayland = Platform.environment['WAYLAND_DISPLAY'] != null;
    final (tool, args) = wayland
        ? ('wl-copy', ['--type', 'image/png'])
        : ('xclip', ['-selection', 'clipboard', '-t', 'image/png', '-i']);
    final Process process;
    try {
      process = await Process.start(tool, args);
    } on ProcessException {
      throw StateError('copying a picture on Linux needs $tool installed');
    }
    process.stdin.add(png);
    await process.stdin.close();
    final code = await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => 0,
    );
    if (code != 0) throw StateError('$tool exited with $code');
  }
}

final imageClipboardProvider = Provider<ImageClipboard>(
  (ref) => const ImageClipboard(),
);

/// Writes [bytes] to [clipboard] and answers what to tell the person. The
/// clipboard takes PNG, so anything else is re-encoded first, off the UI
/// isolate — a large JPEG takes seconds.
Future<String> writeImageToClipboard(
  Uint8List bytes,
  ImageClipboard clipboard,
) async {
  try {
    final png = isPng(bytes) ? bytes : await Isolate.run(() => _toPng(bytes));
    if (png == null) return "Couldn't copy: this image could not be decoded.";
    await clipboard.writePng(png);
    return 'Image copied to clipboard';
  } catch (error) {
    return "Couldn't copy the image: $error";
  }
}

/// Asks where to save [bytes], suggesting [name], and writes them there.
/// Answers what to tell the person, or null when they cancelled.
Future<String?> saveImageAs(Uint8List bytes, String name) async {
  final location = await getSaveLocation(suggestedName: name);
  if (location == null) return null;
  try {
    await File(location.path).writeAsBytes(bytes);
    return 'Saved ${location.path}';
  } on FileSystemException catch (error) {
    return "Couldn't save ${location.path}: ${error.message}";
  }
}

/// Whether [bytes] start with the PNG signature.
bool isPng(Uint8List bytes) =>
    bytes.length >= 8 &&
    bytes[0] == 0x89 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x4E &&
    bytes[3] == 0x47 &&
    bytes[4] == 0x0D &&
    bytes[5] == 0x0A &&
    bytes[6] == 0x1A &&
    bytes[7] == 0x0A;

/// The first frame only: an animated PNG pastes as a still almost everywhere.
Uint8List? _toPng(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  return decoded == null ? null : img.encodePng(decoded, singleFrame: true);
}
