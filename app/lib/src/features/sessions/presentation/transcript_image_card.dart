import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/transcript.dart';

import '../../../core/clipboard/image_clipboard.dart'
    show imageClipboardProvider;
import '../application/transcript_image_reads.dart';
import '../domain/file_preview_kind.dart';

/// One picture as the chat's card, its thumbnails and the viewer see it.
class TranscriptImageView {
  const TranscriptImageView({
    required this.path,
    required this.copyPath,
    required this.read,
    this.environmentId,
    this.onOpen,
  });

  /// As the conversation wrote it; the card's key is made from it.
  final String path;

  /// As the session's environment spells it: what Copy path copies.
  final String copyPath;

  /// Where [copyPath] lives, when the chat placed it.
  final String? environmentId;

  /// Starts the read once and answers the same future after; a transcript
  /// rebuilds on every poll and must not read or decode again.
  final Future<TranscriptImageRead> Function() read;

  /// Reveals the path as a click on it does; null hides Open.
  final VoidCallback? onOpen;

  String get name => path.split(RegExp(r'[\\/]')).last;

  bool get isSvg => previewKindFor(path) == FilePreviewKind.svg;

  TranscriptImageTarget target(Uint8List bytes) =>
      TranscriptImageTarget(path: path, bytes: () async => bytes);
}

/// "1080 × 1754 · 412 KB", as much of it as is known.
String imageMeta(TranscriptImageRead read, {({int width, int height})? size}) {
  final dimensions = size ?? read.dimensions;
  return [
    if (dimensions != null) '${dimensions.width} × ${dimensions.height}',
    if (read.size case final bytes?) formatFileSize(bytes),
  ].join(' · ');
}

/// Copies [path] and says so.
void copyImagePath(BuildContext context, String path) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  unawaited(Clipboard.setData(ClipboardData(text: path)));
  messenger?.showSnackBar(
    const SnackBar(content: Text('Path copied to clipboard')),
  );
}

/// Copy image, where the chat has a menu to run it and this device's
/// clipboard takes a picture; otherwise null.
VoidCallback? copyImageAction(
  BuildContext context,
  WidgetRef ref,
  TranscriptImageView image,
  Uint8List bytes,
) {
  final scope = TranscriptTargetMenuScope.maybeScopeOf(context);
  if (scope == null || !ref.read(imageClipboardProvider).supported) {
    return null;
  }
  return () => unawaited(
    scope.run(context, image.target(bytes), TranscriptTargetAction.copy),
  );
}

/// The picture itself: decoded at [decodeHeight] logical pixels when given,
/// so a thumbnail does not hold a full-size bitmap.
Widget transcriptPicture(
  BuildContext context,
  TranscriptImageView image,
  Uint8List bytes, {
  required BoxFit fit,
  double? decodeHeight,
}) {
  Widget broken(BuildContext context, Object _, StackTrace? _) => Center(
    child: Icon(
      AppIcons.image,
      size: Chrome.icon,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      semanticLabel: '${image.name} could not be displayed',
    ),
  );
  if (image.isSvg) {
    return SvgPicture.memory(bytes, fit: fit, errorBuilder: broken);
  }
  final ImageProvider provider = decodeHeight == null
      ? MemoryImage(bytes)
      : ResizeImage(
          MemoryImage(bytes),
          height: (decodeHeight * MediaQuery.devicePixelRatioOf(context))
              .round(),
        );
  return Image(
    image: provider,
    fit: fit,
    gaplessPlayback: true,
    excludeFromSemantics: true,
    errorBuilder: broken,
  );
}

/// One picture in the chat: a framed card, letterboxed at most
/// [Chrome.inlineImage] tall, with its name, size and actions underneath.
/// Every other state keeps the card's shape: a frame with a spinner while it
/// reads, a dashed row when there is nothing to draw.
class TranscriptImageCard extends ConsumerWidget {
  const TranscriptImageCard({
    required this.image,
    required this.onView,
    this.details = true,
    super.key,
  });

  final TranscriptImageView image;

  /// Opens the viewer at this picture.
  final VoidCallback onView;

  /// False draws the frame alone: a caller with its own caption.
  final bool details;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      FutureBuilder<TranscriptImageRead>(
        future: image.read(),
        builder: (context, snapshot) {
          final read = snapshot.data;
          if (read == null) return _card(context, ref, null);
          if (read.bytes == null) {
            return TranscriptImageNote(name: image.name, note: read.note!);
          }
          return _card(context, ref, read);
        },
      );

  Widget _card(BuildContext context, WidgetRef ref, TranscriptImageRead? read) {
    final scheme = Theme.of(context).colorScheme;
    final bytes = read?.bytes;
    return LayoutBuilder(
      builder: (context, box) {
        final widest = box.maxWidth.isFinite
            ? math.min(box.maxWidth, Chrome.imageCardMaxWidth)
            : Chrome.imageCardMaxWidth;
        final narrowest = math.min(Chrome.imageCardMinWidth, widest);
        final dimensions = read?.dimensions;
        var height = dimensions == null
            ? Chrome.inlineImage
            : dimensions.height
                  .clamp(Chrome.imageThumb, Chrome.inlineImage)
                  .toDouble();
        if (box.maxHeight.isFinite && !details) {
          height = math.min(height, box.maxHeight);
        }
        final drawn = dimensions == null
            ? narrowest
            : dimensions.width *
                  math.min(1.0, Chrome.inlineImage / dimensions.height);
        final width = drawn.clamp(narrowest, widest).toDouble();

        final Widget content = bytes == null
            ? const Center(
                child: InlineSpinner(semanticsLabel: 'Reading image'),
              )
            : transcriptPicture(
                context,
                image,
                bytes,
                fit: BoxFit.scaleDown,
                decodeHeight: height,
              );
        Widget picture = SizedBox(
          width: width,
          height: height,
          child: ColoredBox(
            color: scheme.surfaceContainerLowest,
            child: content,
          ),
        );
        if (bytes != null) {
          picture = TranscriptImageActions(
            target: image.target(bytes),
            child: Semantics(
              button: true,
              label: 'Image ${image.name}. Open the viewer',
              excludeSemantics: true,
              child: Tooltip(
                message: image.name,
                child: InkWell(
                  key: ValueKey('inline-image-${image.path}'),
                  onTap: onView,
                  child: picture,
                ),
              ),
            ),
          );
        } else {
          picture = KeyedSubtree(
            key: ValueKey('inline-image-${image.path}'),
            child: picture,
          );
        }
        return Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: width,
            child: _Frame(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  picture,
                  if (details) ...[
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: scheme.outlineVariant,
                    ),
                    _Details(
                      image: image,
                      meta: read == null ? null : imageMeta(read),
                      onView: bytes == null ? null : onView,
                      onCopyImage: bytes == null
                          ? null
                          : copyImageAction(context, ref, image, bytes),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A square in a strip of several pictures, in the card's frame; tapped, it
/// opens the viewer at its picture. Read only once it is built, which in a
/// lazy strip is when it scrolls into view.
class TranscriptImageThumb extends StatelessWidget {
  const TranscriptImageThumb({
    required this.image,
    required this.onView,
    super.key,
  });

  final TranscriptImageView image;
  final VoidCallback onView;

  @override
  Widget build(BuildContext context) => FutureBuilder<TranscriptImageRead>(
    future: image.read(),
    builder: (context, snapshot) {
      final read = snapshot.data;
      final scheme = Theme.of(context).colorScheme;
      if (read != null && read.bytes == null) {
        return TranscriptImageNote(
          name: image.name,
          note: read.note!,
          square: true,
        );
      }
      final bytes = read?.bytes;
      final tile = SizedBox.square(
        dimension: Chrome.imageThumb,
        child: _Frame(
          child: ColoredBox(
            color: scheme.surfaceContainerLowest,
            child: bytes == null
                ? const Center(
                    child: InlineSpinner(semanticsLabel: 'Reading image'),
                  )
                : transcriptPicture(
                    context,
                    image,
                    bytes,
                    fit: BoxFit.cover,
                    decodeHeight: Chrome.imageThumb,
                  ),
          ),
        ),
      );
      return TranscriptImageActions(
        target: bytes == null ? null : image.target(bytes),
        child: Semantics(
          button: bytes != null,
          label: 'Image ${image.name}',
          excludeSemantics: true,
          child: Tooltip(
            message: image.name,
            child: InkWell(
              key: ValueKey('inline-image-${image.path}'),
              onTap: bytes == null ? null : onView,
              borderRadius: BorderRadius.circular(Radii.md),
              child: tile,
            ),
          ),
        ),
      );
    },
  );
}

/// The card's shape when there is no picture to draw: a dashed outline round
/// the name and why — "is no longer on disk".
class TranscriptImageNote extends StatelessWidget {
  const TranscriptImageNote({
    required this.name,
    required this.note,
    this.square = false,
    super.key,
  });

  final String name;
  final String note;

  /// The strip's square, for a thumbnail.
  final bool square;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final style = theme.textTheme.labelSmall?.copyWith(color: muted);
    final glyph = Icon(AppIcons.image, size: Chrome.iconSmall, color: muted);
    final outline = CustomPaint(
      painter: _DashedOutline(color: theme.colorScheme.outline),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.smd,
          vertical: Insets.sm,
        ),
        child: square
            ? Center(
                child: Text(
                  note,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: style,
                ),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  glyph,
                  const SizedBox(width: Insets.sm),
                  Flexible(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: name,
                            style: MonoStyles.small.copyWith(
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                          TextSpan(text: ' $note'),
                        ],
                      ),
                      style: style,
                    ),
                  ),
                ],
              ),
      ),
    );
    return Semantics(
      label: '$name $note',
      excludeSemantics: true,
      child: square
          ? Tooltip(
              message: '$name $note',
              child: SizedBox.square(
                dimension: Chrome.imageThumb,
                child: outline,
              ),
            )
          : Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: Chrome.imageCardMaxWidth,
                ),
                child: outline,
              ),
            ),
    );
  }
}

/// The card's frame: an outline on a surface container, its corners clipped.
class _Frame extends StatelessWidget {
  const _Frame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.md),
        child: ColoredBox(color: scheme.surfaceContainer, child: child),
      ),
    );
  }
}

/// The strip under the picture: its name and size, then Open, Copy image and
/// a menu holding Copy path.
class _Details extends StatelessWidget {
  const _Details({
    required this.image,
    required this.meta,
    required this.onView,
    required this.onCopyImage,
  });

  final TranscriptImageView image;
  final String? meta;
  final VoidCallback? onView;
  final VoidCallback? onCopyImage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final density = UiDensity.of(context);
    final meta = this.meta;
    Widget button({
      required String key,
      required String tooltip,
      required IconData icon,
      required VoidCallback onPressed,
    }) => IconButton(
      key: ValueKey(key),
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon),
      iconSize: density.iconSize(Chrome.iconAction),
      padding: EdgeInsets.zero,
      // Standard, so the constraints are the size: compact took 8px off
      // them and left an 18px target under a pointer.
      visualDensity: VisualDensity.standard,
      constraints: density.iconConstraints(Chrome.control),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.smd,
        Insets.xs,
        Insets.xs,
        Insets.xs,
      ),
      child: Row(
        children: [
          Icon(
            AppIcons.image,
            size: density.iconSize(Chrome.iconSmall),
            color: muted,
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  image.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MonoStyles.body.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                if (meta != null && meta.isNotEmpty)
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(color: muted),
                  ),
              ],
            ),
          ),
          if (image.onOpen case final open?)
            button(
              key: 'inline-image-open',
              tooltip: 'Open',
              icon: AppIcons.arrowSquareOut,
              onPressed: open,
            ),
          if (onCopyImage case final copy?)
            button(
              key: 'inline-image-copy-image',
              tooltip: 'Copy image',
              icon: AppIcons.copySimple,
              onPressed: copy,
            ),
          MenuAnchor(
            menuChildren: [
              MenuItemButton(
                key: const ValueKey('inline-image-copy'),
                leadingIcon: const Icon(AppIcons.linkSimple),
                onPressed: () => copyImagePath(context, image.copyPath),
                child: const Text('Copy path'),
              ),
              if (onView case final view?)
                MenuItemButton(
                  key: const ValueKey('inline-image-view'),
                  leadingIcon: const Icon(AppIcons.arrowsOutSimple),
                  onPressed: view,
                  child: const Text('View full size'),
                ),
            ],
            builder: (context, menu, _) => button(
              key: 'inline-image-more',
              tooltip: 'More',
              icon: AppIcons.dotsThree,
              onPressed: () => menu.isOpen ? menu.close() : menu.open(),
            ),
          ),
        ],
      ),
    );
  }
}

/// A rounded outline drawn in dashes: the mark of a picture that is not
/// there, where a solid frame would promise one.
class _DashedOutline extends CustomPainter {
  const _DashedOutline({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final outline = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(0.5),
          const Radius.circular(Radii.md),
        ),
      );
    for (final metric in outline.computeMetrics()) {
      for (var at = 0.0; at < metric.length; at += Insets.xs * 2) {
        canvas.drawPath(metric.extractPath(at, at + Insets.xs), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedOutline old) => old.color != color;
}
