import 'dart:io';

import 'package:flutter/material.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:agent_cli/stream.dart';

/// How big a file may be before we refuse to hand it to the decoder: a decode
/// allocates `width * height * 4` bytes whatever the file weighs.
const int kMaxImagePreviewBytes = 12 * 1024 * 1024;

/// The tallest a preview draws inline. Wide images letterbox rather than push
/// the rest of the conversation off the screen; the viewer shows them whole.
const double kInlineImageMaxHeight = 220;

/// The frame a preview always occupies, whatever it is holding: the thumbnail
/// is a control, and one sized by its picture has no size until the decode ends.
const double kInlineImageMinWidth = 120;
const double kInlineImageMinHeight = 72;

/// Brings a picture a server elsewhere holds to a file this machine can draw.
/// Throws an [Exception] whose text is the sentence to show when it cannot.
typedef TranscriptImageFetch = Future<File> Function(String path);

/// Where the previews below it bring their pictures from: set around a
/// transcript whose server is not on this machine (Stage 0 step 10). A null
/// [fetch] reads this disk, as before.
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

/// The picture behind a transcript row that read an image, drawn from the path
/// rather than the transcript's base64 copy. Every failure degrades to a line.
class TranscriptImagePreview extends StatefulWidget {
  const TranscriptImagePreview({
    required this.path,
    this.resolveHostPath,
    this.fetch,
    this.maxBytes = kMaxImagePreviewBytes,
    super.key,
  });

  /// The path as the agent wrote it.
  final String path;

  /// Translates [path] into one this process can open, or returns null when it
  /// cannot. Omitted means "already a host path".
  final String? Function(String path)? resolveHostPath;

  /// Brings [path] from the server instead of reading it here; when null, the
  /// nearest [TranscriptImageSource]'s. [resolveHostPath] is then unused.
  final TranscriptImageFetch? fetch;

  final int maxBytes;

  @override
  State<TranscriptImagePreview> createState() => _TranscriptImagePreviewState();
}

class _TranscriptImagePreviewState extends State<TranscriptImagePreview> {
  File? _file;
  String? _problem;
  bool _fetching = false;
  bool _resolved = false;
  TranscriptImageFetch? _fetch;

  /// Bumped per resolve, so a fetch that lands after the path moved is dropped.
  int _asked = 0;

  // A fetch rebuilt for the same path is the same fetch: only a path, or a
  // switch between this disk and a server's, resolves again.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final fetch = widget.fetch ?? TranscriptImageSource.of(context);
    if (!_resolved || (fetch == null) != (_fetch == null)) _resolve(fetch);
  }

  @override
  void didUpdateWidget(TranscriptImagePreview old) {
    super.didUpdateWidget(old);
    final fetch = widget.fetch ?? TranscriptImageSource.of(context);
    if (old.path != widget.path ||
        old.maxBytes != widget.maxBytes ||
        (fetch == null) != (_fetch == null)) {
      _resolve(fetch);
    }
  }

  void _resolve(TranscriptImageFetch? fetch) {
    _resolved = true;
    _fetch = fetch;
    _file = null;
    _problem = null;
    _fetching = false;
    final asked = ++_asked;
    if (fetch == null) {
      _resolveHere();
      return;
    }
    if (!looksLikeImagePath(widget.path)) {
      _problem = 'That file is not an image.';
      return;
    }
    _fetching = true;
    fetch(widget.path).then(
      (file) {
        if (!mounted || asked != _asked) return;
        setState(() {
          _fetching = false;
          _file = file;
        });
      },
      onError: (Object error) {
        if (!mounted || asked != _asked) return;
        setState(() {
          _fetching = false;
          _problem = error is Exception
              ? '$error'
              : 'That image could not be opened.';
        });
      },
    );
  }

  /// Stats the file **once per path**, not once per build: the transcript
  /// rebuilds on every poll, and a `\\wsl.localhost\…` stat costs ~1.2 ms.
  void _resolveHere() {
    final translated = _hostPath();
    if (translated == null) {
      _problem = 'That image is no longer on disk.';
      return;
    }
    if (!looksLikeImagePath(translated)) {
      _problem = 'That file is not an image.';
      return;
    }
    try {
      final file = File(translated);
      final stat = file.statSync();
      if (stat.type == FileSystemEntityType.notFound) {
        _problem = missingImageNote(widget.path);
      } else if (stat.size > widget.maxBytes) {
        _problem =
            'That image is too large to preview here '
            '(${_megabytes(stat.size)}).';
      } else {
        _file = file;
      }
    } catch (_) {
      // A locked file, a share that went away, a path this platform rejects.
      _problem = 'That image could not be opened.';
    }
  }

  /// The path in *this* process's terms, or null when translation failed.
  String? _hostPath() {
    final resolve = widget.resolveHostPath;
    if (resolve == null) return widget.path;
    try {
      return resolve(widget.path) ?? widget.path;
    } catch (_) {
      // A translator that throws is a translator that could not answer.
      return widget.path;
    }
  }

  static String _megabytes(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  void _open() {
    final file = _file;
    if (file == null) return;
    showDialog<void>(
      context: context,
      builder: (context) => _ImageViewerDialog(file: file, label: widget.path),
    );
  }

  @override
  Widget build(BuildContext context) {
    final file = _file;
    if (_fetching) return const _Note(text: 'Bringing the image here…');
    if (file == null) return _Note(text: _problem ?? 'No preview.');

    final scheme = Theme.of(context).colorScheme;
    final name = widget.path.split(RegExp(r'[\\/]')).last;
    return Align(
      alignment: Alignment.centerLeft,
      child: Semantics(
        button: true,
        label: 'Open image $name',
        child: Tooltip(
          message: 'Open $name',
          child: InkWell(
            onTap: _open,
            borderRadius: BorderRadius.circular(Radii.sm),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: kInlineImageMinWidth,
                minHeight: kInlineImageMinHeight,
                maxHeight: kInlineImageMaxHeight,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: scheme.outlineVariant),
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(Radii.sm),
                  child: Image.file(
                    file,
                    fit: BoxFit.contain,
                    // A file that exists and still will not decode: a truncated
                    // screenshot, a `.png` that is really something else.
                    errorBuilder: (context, _, _) =>
                        const _Note(text: 'That image could not be displayed.'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The degraded form: one quiet line in place of the picture. It never repeats
/// the file name — the row above already carries the path.
class _Note extends StatelessWidget {
  const _Note({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          AppIcons.image,
          size: Chrome.iconSmall,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: Insets.xs),
        Flexible(
          child: Text(
            text,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// The image at full size, pannable and zoomable.
class _ImageViewerDialog extends StatelessWidget {
  const _ImageViewerDialog({required this.file, required this.label});

  final File file;

  /// The path as the agent wrote it — shown here, where there is room for it,
  /// rather than under the thumbnail where the row already says it.
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A phone gives the picture the whole screen to pinch in.
    final fullScreen = WidthClass.of(
      MediaQuery.sizeOf(context).width,
    ).isCompact;
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.md,
            Insets.sm,
            Insets.xs,
            Insets.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: MonoStyles.small.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(AppIcons.x, size: Chrome.icon),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Flexible(
          child: InteractiveViewer(
            maxScale: 8,
            child: Image.file(
              file,
              fit: BoxFit.contain,
              errorBuilder: (context, _, _) => const Padding(
                padding: EdgeInsets.all(Insets.lg),
                child: _Note(text: 'That image could not be displayed.'),
              ),
            ),
          ),
        ),
      ],
    );
    if (fullScreen) {
      return Dialog.fullscreen(child: SafeArea(child: body));
    }
    return Dialog(insetPadding: const EdgeInsets.all(Insets.xl), child: body);
  }
}
