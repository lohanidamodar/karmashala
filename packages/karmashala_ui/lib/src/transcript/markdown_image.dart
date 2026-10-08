import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../app_icons.dart';
import '../design_tokens.dart';
import 'transcript_target_menu.dart';

/// Draws a picture a message embeds as `![alt](path)`, from the path as written.
typedef MarkdownLocalImageBuilder =
    Widget Function(BuildContext context, String path, String? alt);

/// Where the [MarkdownMessage]s below it draw their local pictures from. With
/// none, a local picture is its alt text: nothing reads a disk by itself.
class MarkdownImageScope extends InheritedWidget {
  const MarkdownImageScope({
    required this.builder,
    required super.child,
    super.key,
  });

  final MarkdownLocalImageBuilder builder;

  static MarkdownLocalImageBuilder? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MarkdownImageScope>()?.builder;

  @override
  bool updateShouldNotify(MarkdownImageScope old) => builder != old.builder;
}

/// The file path a markdown image names, or null when it names no file.
String? markdownImagePath(Uri uri) {
  String decoded(String path) {
    try {
      return Uri.decodeComponent(path);
    } on ArgumentError {
      return path;
    }
  }

  final scheme = uri.scheme.toLowerCase();
  if (scheme.isEmpty) return decoded(uri.path);
  // `C:\x\a.png` parses with `c` as its scheme.
  if (scheme.length == 1) return '${scheme.toUpperCase()}:${decoded(uri.path)}';
  if (scheme == 'file') {
    final path = decoded(uri.path);
    return RegExp(r'^/[A-Za-z]:').hasMatch(path) ? path.substring(1) : path;
  }
  return null;
}

/// One `![alt](src)`: a web picture only once asked, since fetching it tells
/// that host this machine's address; a local one through [MarkdownImageScope].
class MarkdownImage extends StatelessWidget {
  const MarkdownImage({required this.uri, this.alt, super.key});

  final Uri uri;
  final String? alt;

  @override
  Widget build(BuildContext context) {
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'http' || scheme == 'https') {
      return _WebImage(uri: uri, alt: alt);
    }
    if (scheme == 'data') {
      final bytes = _dataBytes(uri);
      if (bytes != null) {
        return TranscriptImageActions(
          target: TranscriptImageTarget(bytes: () async => bytes),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: Chrome.inlineImage),
            child: Image.memory(
              bytes,
              fit: BoxFit.contain,
              semanticLabel: alt,
              errorBuilder: (context, _, _) => _AltNote(alt: alt),
            ),
          ),
        );
      }
    }
    final path = markdownImagePath(uri);
    final local = MarkdownImageScope.of(context);
    if (path == null || local == null) return _AltNote(alt: alt ?? path);
    return local(context, path, alt);
  }

  static Uint8List? _dataBytes(Uri uri) {
    try {
      return uri.data?.contentAsBytes();
    } on FormatException {
      return null;
    }
  }
}

class _WebImage extends StatefulWidget {
  const _WebImage({required this.uri, this.alt});

  final Uri uri;
  final String? alt;

  @override
  State<_WebImage> createState() => _WebImageState();
}

class _WebImageState extends State<_WebImage> {
  bool _load = false;

  @override
  void didUpdateWidget(_WebImage old) {
    super.didUpdateWidget(old);
    if (old.uri != widget.uri) _load = false;
  }

  @override
  Widget build(BuildContext context) {
    if (!_load) {
      return Tooltip(
        message: widget.alt ?? widget.uri.toString(),
        child: TextButton.icon(
          key: const ValueKey('markdown-image-load'),
          onPressed: () => setState(() => _load = true),
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            textStyle: Theme.of(context).textTheme.labelSmall,
          ),
          icon: const Icon(AppIcons.image, size: Chrome.iconSmall),
          label: Text('Load image from ${widget.uri.host}'),
        ),
      );
    }
    final image = NetworkImage(widget.uri.toString());
    return TranscriptImageActions(
      target: TranscriptImageTarget(
        uri: widget.uri,
        bytes: () => imageProviderPng(image),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: Chrome.inlineImage),
        child: Image(
          image: image,
          fit: BoxFit.contain,
          semanticLabel: widget.alt,
          errorBuilder: (context, _, _) =>
              const _AltNote(alt: 'The image did not load.'),
        ),
      ),
    );
  }
}

/// The first frame [provider] draws, as PNG; null when it does not load.
Future<Uint8List?> imageProviderPng(ImageProvider provider) async {
  final done = Completer<ui.Image?>();
  final stream = provider.resolve(ImageConfiguration.empty);
  final listener = ImageStreamListener(
    (info, _) {
      if (!done.isCompleted) done.complete(info.image.clone());
      info.dispose();
    },
    onError: (_, _) {
      if (!done.isCompleted) done.complete(null);
    },
  );
  stream.addListener(listener);
  final image = await done.future;
  stream.removeListener(listener);
  if (image == null) return null;
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

class _AltNote extends StatelessWidget {
  const _AltNote({this.alt});

  final String? alt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(AppIcons.image, size: Chrome.iconSmall, color: muted),
        const SizedBox(width: Insets.xs),
        Flexible(
          child: Text(
            (alt == null || alt!.isEmpty) ? 'Image' : alt!,
            style: theme.textTheme.labelSmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}
