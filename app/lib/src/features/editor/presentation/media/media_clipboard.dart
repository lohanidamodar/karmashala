import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:pasteboard/pasteboard.dart';

/// Puts [bytes] on the clipboard as a picture, and says so the way
/// `copyToClipboard` does. The clipboard takes PNG, so anything else is
/// re-encoded first, off the UI isolate — a large JPEG takes seconds. Never
/// throws: a failure is said instead.
Future<void> copyImageToClipboard(BuildContext context, Uint8List bytes) async {
  String message;
  try {
    final png = isPng(bytes) ? bytes : await Isolate.run(() => _toPng(bytes));
    if (png == null) {
      message = "Couldn't copy: this image could not be decoded.";
    } else {
      await Pasteboard.writeImage(png);
      message = 'Image copied to clipboard';
    }
  } catch (error) {
    message = "Couldn't copy the image: $error";
  }
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(message)));
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
