import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';

import '../../../../core/clipboard/image_clipboard.dart';

export '../../../../core/clipboard/image_clipboard.dart'
    show ImageClipboard, imageClipboardProvider, isPng, writeImageToClipboard;

/// Puts [bytes] on the clipboard as a picture, and says so the way
/// `copyToClipboard` does. Never throws: a failure is said instead.
Future<void> copyImageToClipboard(
  BuildContext context,
  Uint8List bytes, {
  ImageClipboard clipboard = const ImageClipboard(),
}) async {
  final message = await writeImageToClipboard(bytes, clipboard);
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(message)));
}
