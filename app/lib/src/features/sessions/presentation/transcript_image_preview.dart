import 'dart:io';

import 'package:flutter/material.dart';

import 'transcript_inline_images.dart';

/// How big a file may be before we refuse to hand it to the decoder: a decode
/// allocates `width * height * 4` bytes whatever the file weighs.
const int kMaxImagePreviewBytes = 12 * 1024 * 1024;

/// Brings a picture a server elsewhere holds to a file this machine can draw.
/// Throws an [Exception] whose text is the sentence to show when it cannot.
typedef TranscriptImageFetch = Future<File> Function(String path);

/// Where the previews below it bring their pictures from: set around a
/// transcript whose server is not on this machine (Stage 0 step 10). A null
/// [fetch] reads this disk, as before. Under [TranscriptInlineImages] the
/// chat reads through the server instead, wherever it is.
class TranscriptImageSource extends InheritedWidget {
  const TranscriptImageSource({
    required this.fetch,
    required super.child,
    super.key,
  });

  final TranscriptImageFetch? fetch;

  static TranscriptImageFetch? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<TranscriptImageSource>()
      ?.fetch;

  @override
  bool updateShouldNotify(TranscriptImageSource old) => fetch != old.fetch;
}

/// One picture a row holds by path — one a tool returned, one somebody
/// pasted, one the media list found — drawn as the chat's card. Every failure
/// keeps the card's shape and says why.
class TranscriptImagePreview extends StatelessWidget {
  const TranscriptImagePreview({
    required this.path,
    this.resolveHostPath,
    this.fetch,
    this.maxBytes = kMaxImagePreviewBytes,
    this.details = true,
    super.key,
  });

  /// The path as the agent wrote it.
  final String path;

  /// Translates [path] into one this process can open, or returns null when it
  /// cannot; used only when the picture is read from this disk.
  final String? Function(String path)? resolveHostPath;

  /// Brings [path] from the server instead of reading it any other way.
  final TranscriptImageFetch? fetch;

  final int maxBytes;

  /// False draws the frame alone, for a caller with its own caption.
  final bool details;

  @override
  Widget build(BuildContext context) => TranscriptImageStrip(
    paths: const [],
    returned: [path],
    resolveHostPath: resolveHostPath,
    fetch: fetch,
    maxBytes: maxBytes,
    details: details,
  );
}
