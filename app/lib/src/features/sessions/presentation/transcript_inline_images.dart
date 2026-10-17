import 'dart:async';

import 'package:agent_cli/process.dart'
    show EnvironmentPath, localHostEnvironmentId;
import 'package:agent_cli/stream.dart' show isCachedToolImage, pathFromFileUri;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_session/transcript.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/transcript.dart';

import '../application/file_preview_loader.dart';
import '../application/transcript_image_reads.dart';
import 'transcript_image_card.dart';
import 'transcript_image_preview.dart'
    show TranscriptImageFetch, TranscriptImageSource, kMaxImagePreviewBytes;
import 'transcript_image_viewer.dart';

/// The most pictures one row draws; the rest are counted, not fetched.
const int kInlineImageStripMax = 24;

/// Places a path the conversation wrote in the session's environment, or null
/// when there is no record of where the session runs.
typedef InlineImagePlace = EnvironmentPath? Function(String path);

/// Lets the rows below draw the pictures their text names, and the ones their
/// tools returned, read through the server wherever the session runs. With
/// none above, rows draw no named pictures.
class TranscriptInlineImages extends StatelessWidget {
  const TranscriptInlineImages({
    required this.place,
    required this.child,
    this.onOpen,
    super.key,
  });

  final InlineImagePlace place;

  /// Reveals a path as a click on it does; null hides Open.
  final ValueChanged<String>? onOpen;
  final Widget child;

  @override
  Widget build(BuildContext context) => _InlineImageScope(
    place: place,
    onOpen: onOpen,
    child: MarkdownImageScope(builder: _markdownImage, child: child),
  );
}

Widget _markdownImage(BuildContext context, String path, String? alt) =>
    TranscriptImageStrip(paths: [path]);

class _InlineImageScope extends InheritedWidget {
  const _InlineImageScope({
    required this.place,
    required this.onOpen,
    required super.child,
  });

  final InlineImagePlace place;
  final ValueChanged<String>? onOpen;

  static _InlineImageScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_InlineImageScope>();

  @override
  bool updateShouldNotify(_InlineImageScope old) =>
      place != old.place || onOpen != old.onOpen;
}

/// Whether [path] names a picture drawn inline.
bool isInlineImagePath(String path) => isTranscriptPicture(path);

final _markdownImageSyntax = RegExp(r'!\[[^\]\n]*\]\([^)\n]*\)');

/// A picture named with no folder, `shot.png`, which the path links leave
/// alone; never the tail of a longer path or address.
final _bareImageName = RegExp(
  r'(?<![\w.+%@:~/\\-])[\w+%@-]+(?:\.[\w+%@-]+)*\.(?:png|jpe?g|gif|webp|svg|bmp)(?![\w+%@/\\-])',
  caseSensitive: false,
);

/// The picture paths [text] names, in order and once each. Those it embeds
/// as `![alt](path)` are left out: the markdown draws them where they stand.
List<String> inlineImagePaths(String? text) {
  if (text == null || text.isEmpty) return const [];
  final plain = text.replaceAll(_markdownImageSyntax, ' ');
  final found = <(int, String)>[
    for (final match in kTranscriptPathPattern.allMatches(plain))
      if (tokenForMatch(match[0]!).path case final path
          when isInlineImagePath(path))
        (match.start, path),
    for (final match in _bareImageName.allMatches(plain))
      (match.start, match[0]!),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  return {for (final (_, path) in found) path}.toList();
}

/// The pictures one row shows: those its text [paths] names and those its
/// tool [returned], each drawn once however it was spelled — one card, or
/// several as a strip of thumbnails built, and so read, only as they scroll
/// into view. A tap opens the viewer on all of them.
///
/// Every picture is read one way: placed in the session's environment and
/// read through the server, as the chat's paths are. Only a [returned] one
/// with no [TranscriptInlineImages] above — the queue, the media list — falls
/// back to [fetch], the nearest [TranscriptImageSource], or this disk.
class TranscriptImageStrip extends ConsumerStatefulWidget {
  const TranscriptImageStrip({
    required this.paths,
    this.returned = const [],
    this.resolveHostPath,
    this.fetch,
    this.maxBytes = kMaxImagePreviewBytes,
    this.details = true,
    super.key,
  });

  final List<String> paths;
  final List<String> returned;

  /// Translates a returned path for this disk, when it is read here.
  final String? Function(String path)? resolveHostPath;

  /// Brings a returned path from the server instead of any other way.
  final TranscriptImageFetch? fetch;

  final int maxBytes;

  /// False draws a single picture's frame without the strip under it.
  final bool details;

  @override
  ConsumerState<TranscriptImageStrip> createState() =>
      _TranscriptImageStripState();
}

class _TranscriptImageStripState extends ConsumerState<TranscriptImageStrip> {
  /// One read per picture, kept across rebuilds.
  final _reads = <String, Future<TranscriptImageRead>>{};
  Object? _source;
  ValueChanged<String>? _onOpen;
  List<TranscriptImageView>? _images;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sourceChanged();
  }

  @override
  void didUpdateWidget(TranscriptImageStrip old) {
    super.didUpdateWidget(old);
    if (!listEquals(old.paths, widget.paths) ||
        !listEquals(old.returned, widget.returned) ||
        old.maxBytes != widget.maxBytes) {
      _images = null;
    }
    _sourceChanged();
  }

  /// A new way to read drops what the old one read; a fetch rebuilt for the
  /// same server is the same way.
  void _sourceChanged() {
    final scope = _InlineImageScope.of(context);
    // A new Open is a new action on the same pictures, not a new read.
    if (scope?.onOpen != _onOpen) {
      _onOpen = scope?.onOpen;
      _images = null;
    }
    final source = (
      scope?.place,
      widget.fetch == null,
      TranscriptImageSource.of(context) == null,
    );
    if (source == _source) return;
    _source = source;
    _reads.clear();
    _images = null;
  }

  List<TranscriptImageView> _resolve() {
    final scope = _InlineImageScope.of(context);
    final byKey = <String, TranscriptImageView>{};
    void add(String written, {required bool returned}) {
      final path = pathFromFileUri(written);
      final image = _imageFor(path, scope: scope, returned: returned);
      if (image != null) byKey.putIfAbsent(image.$1, () => image.$2);
    }

    for (final path in widget.returned) {
      add(path, returned: true);
    }
    if (scope != null) {
      for (final path in widget.paths) {
        add(path, returned: false);
      }
    }
    return byKey.values.toList();
  }

  /// The picture at [path] and the key it is drawn once under, or null for a
  /// named one with nowhere to read it.
  (String, TranscriptImageView)? _imageFor(
    String path, {
    required _InlineImageScope? scope,
    required bool returned,
  }) {
    final explicit = widget.fetch;
    if (explicit != null) {
      return _view('fetch', path, path, null, () {
        return readFetchedImage(explicit, path, maxBytes: widget.maxBytes);
      });
    }
    if (scope != null) {
      // A tool image the server cached is spelled on the server's machine.
      final placed = isCachedToolImage(path)
          ? EnvironmentPath(environmentId: localHostEnvironmentId, path: path)
          : scope.place(path);
      final open = scope.onOpen;
      if (placed == null) {
        return _view(
          'unplaced',
          path,
          path,
          null,
          () => Future.value(
            const TranscriptImageRead.failed(kUnplacedImageNote),
          ),
          onOpen: open == null ? null : () => open(path),
        );
      }
      final loader = ref.read(filePreviewLoaderProvider);
      return _view(
        placed.environmentId,
        path,
        placed.path,
        placed.environmentId,
        () => readImageThroughServer(loader, placed),
        onOpen: open == null ? null : () => open(path),
      );
    }
    if (!returned) return null;
    if (TranscriptImageSource.of(context) case final fetch?) {
      return _view('source', path, path, null, () {
        return readFetchedImage(fetch, path, maxBytes: widget.maxBytes);
      });
    }
    final resolve = widget.resolveHostPath;
    return _view('disk', path, path, null, () {
      return readImageFromDisk(
        path,
        resolveHostPath: resolve,
        maxBytes: widget.maxBytes,
      );
    });
  }

  (String, TranscriptImageView) _view(
    String where,
    String path,
    String copyPath,
    String? environmentId,
    Future<TranscriptImageRead> Function() start, {
    VoidCallback? onOpen,
  }) {
    final key = '$where|${_sameFile(copyPath)}';
    return (
      key,
      TranscriptImageView(
        path: path,
        copyPath: copyPath,
        environmentId: environmentId,
        read: () => _reads.putIfAbsent(key, start),
        onOpen: onOpen,
      ),
    );
  }

  /// One spelling per file: `C:/tmp/a.png` and `c:\tmp\a.png` are one.
  static String _sameFile(String path) {
    final slashed = path.replaceAll(r'\', '/');
    return RegExp(r'^([A-Za-z]:|//)').hasMatch(slashed)
        ? slashed.toLowerCase()
        : slashed;
  }

  void _openViewer(List<TranscriptImageView> images, int index) => unawaited(
    showTranscriptImageViewer(context, images: images, initial: index),
  );

  @override
  Widget build(BuildContext context) {
    final images = _images ??= _resolve();
    if (images.isEmpty) return const SizedBox.shrink();
    final shown = images.length > kInlineImageStripMax
        ? images.sublist(0, kInlineImageStripMax)
        : images;
    final hidden = images.length - shown.length;
    final Widget body;
    if (shown.length == 1) {
      body = TranscriptImageCard(
        image: shown.single,
        details: widget.details,
        onView: () => _openViewer(shown, 0),
      );
      // The bare frame fills a caller's box, so it is handed that box whole.
      if (!widget.details) return SelectionContainer.disabled(child: body);
    } else {
      body = SizedBox(
        key: const ValueKey('inline-image-strip'),
        height: Chrome.imageThumb,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: shown.length,
          separatorBuilder: (_, _) => const SizedBox(width: Insets.xs),
          itemBuilder: (context, i) => TranscriptImageThumb(
            image: shown[i],
            onView: () => _openViewer(shown, i),
          ),
        ),
      );
    }
    final theme = Theme.of(context);
    return SelectionContainer.disabled(
      child: Padding(
        padding: const EdgeInsets.only(top: Insets.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            body,
            if (hidden > 0)
              Padding(
                padding: const EdgeInsets.only(top: Insets.xs),
                child: Text(
                  'and $hidden more',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
