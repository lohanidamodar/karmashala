import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/transcript.dart';

import '../../editor/presentation/media/image_viewer.dart';
import '../../environments/application/environments_controller.dart'
    show environmentLabelForIdProvider;
import '../application/transcript_image_reads.dart';
import 'chat_target_menu.dart' show keepTranscriptTargetMenu;
import 'transcript_image_card.dart';

/// Opens the lightbox on [images] at [initial]: the whole screen on a phone,
/// a large dialog elsewhere. The chat's menu is carried over its route.
Future<void> showTranscriptImageViewer(
  BuildContext context, {
  required List<TranscriptImageView> images,
  int initial = 0,
}) {
  final fullScreen = WidthClass.of(MediaQuery.sizeOf(context).width).isCompact;
  final viewer = keepTranscriptTargetMenu(
    context,
    TranscriptImageViewer(
      images: images,
      initial: initial,
      fullScreen: fullScreen,
    ),
  );
  return showDialog<void>(
    context: context,
    builder: (_) => fullScreen
        ? Dialog.fullscreen(child: SafeArea(child: viewer))
        : Dialog(
            insetPadding: const EdgeInsets.all(Insets.xl),
            clipBehavior: Clip.antiAlias,
            child: viewer,
          ),
  );
}

/// The lightbox: the picture on a dark ground, pannable and zoomable, with
/// its name, zoom and actions above, and — for several — previous, next and
/// a filmstrip. Its keys are its own: Esc, `+`, `-`, `0` and the arrows act
/// only while focus is inside it.
class TranscriptImageViewer extends ConsumerStatefulWidget {
  const TranscriptImageViewer({
    required this.images,
    this.initial = 0,
    this.fullScreen = false,
    super.key,
  });

  final List<TranscriptImageView> images;
  final int initial;

  /// A phone: the filmstrip folds away and the toolbar keeps only Close and ⋯.
  final bool fullScreen;

  @override
  ConsumerState<TranscriptImageViewer> createState() =>
      _TranscriptImageViewerState();
}

class _TranscriptImageViewerState extends ConsumerState<TranscriptImageViewer> {
  late int _index = widget.initial.clamp(0, widget.images.length - 1);
  final _zoom = ImageViewerController();

  /// The decoded size of the picture shown, once it decodes.
  ({int width, int height})? _decoded;

  /// The reader zoomed by hand, so a swipe pans rather than turns the page.
  bool _zoomed = false;

  final _touches = <int>{};
  Offset? _swipeFrom;
  bool _pinched = false;

  TranscriptImageView get _image => widget.images[_index];
  int get _count => widget.images.length;

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  void _go(int index) {
    if (index < 0 || index >= _count || index == _index) return;
    setState(() {
      _index = index;
      _decoded = null;
      _zoomed = false;
    });
  }

  void _zoomBy(void Function() step) {
    _zoomed = true;
    step();
  }

  void _fit() {
    _zoomed = false;
    _zoom.fit();
  }

  void _close() => Navigator.of(context).pop();

  void _open(VoidCallback open) {
    Navigator.of(context).pop();
    open();
  }

  String? _where(String? environmentId) {
    if (environmentId == null) return null;
    try {
      return ref.read(environmentLabelForIdProvider(environmentId));
    } catch (_) {
      // No environments to name it by — a test, or a list not loaded.
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _close,
        const CharacterActivator('+'): () => _zoomBy(_zoom.zoomIn),
        const CharacterActivator('='): () => _zoomBy(_zoom.zoomIn),
        const CharacterActivator('-'): () => _zoomBy(_zoom.zoomOut),
        const CharacterActivator('0'): _fit,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _go(_index - 1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _go(_index + 1),
      },
      child: Focus(
        autofocus: true,
        child: FutureBuilder<TranscriptImageRead>(
          future: image.read(),
          builder: (context, snapshot) {
            final read = snapshot.data;
            final scheme = Theme.of(context).colorScheme;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _toolbar(context, image, read),
                Divider(height: 1, thickness: 1, color: scheme.outlineVariant),
                Expanded(child: _stage(context, image, read)),
                if (_count > 1 && !widget.fullScreen) ...[
                  Divider(
                    height: 1,
                    thickness: 1,
                    color: scheme.outlineVariant,
                  ),
                  _filmstrip(context),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _toolbar(
    BuildContext context,
    TranscriptImageView image,
    TranscriptImageRead? read,
  ) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final bytes = read?.bytes;
    final zoomable = bytes != null && !image.isSvg;
    final copyImage = bytes == null
        ? null
        : copyImageAction(context, ref, image, bytes);
    final open = image.onOpen;
    final meta = [
      if (read != null && read.bytes != null) imageMeta(read, size: _decoded),
      ?_where(image.environmentId),
      if (_count > 1 && widget.fullScreen) '${_index + 1} of $_count',
    ].where((part) => part.isNotEmpty).join(' · ');
    final heading = Row(
      children: [
        Icon(AppIcons.image, size: Chrome.icon, color: muted),
        const SizedBox(width: Insets.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                image.name,
                key: const ValueKey('image-viewer-name'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: MonoStyles.label.copyWith(
                  color: theme.colorScheme.onSurface,
                ),
              ),
              if (meta.isNotEmpty)
                Text(
                  meta,
                  key: const ValueKey('image-viewer-meta'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(color: muted),
                ),
            ],
          ),
        ),
      ],
    );
    final close = IconButton(
      key: const ValueKey('image-viewer-close'),
      tooltip: 'Close',
      icon: const Icon(AppIcons.x),
      onPressed: _close,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.lg,
        Insets.xs,
        Insets.xs,
        Insets.xs,
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final roomy =
              !widget.fullScreen &&
              WidthClass.of(
                box.maxWidth,
                textScaler: MediaQuery.textScalerOf(context),
              ).isExpanded;
          if (!roomy) {
            return Row(
              children: [
                Expanded(child: heading),
                MenuAnchor(
                  menuChildren: [
                    if (zoomable) ...[
                      MenuItemButton(
                        key: const ValueKey('image-viewer-menu-fit'),
                        leadingIcon: const Icon(AppIcons.arrowsOutSimple),
                        onPressed: _fit,
                        child: const Text('Fit'),
                      ),
                      MenuItemButton(
                        key: const ValueKey('image-viewer-menu-actual'),
                        leadingIcon: const Icon(AppIcons.magnifyingGlass),
                        onPressed: () => _zoomBy(_zoom.actualSize),
                        child: const Text('Actual size (1:1)'),
                      ),
                    ],
                    if (copyImage != null)
                      MenuItemButton(
                        key: const ValueKey('image-viewer-menu-copy-image'),
                        leadingIcon: const Icon(AppIcons.copySimple),
                        onPressed: copyImage,
                        child: const Text('Copy image'),
                      ),
                    MenuItemButton(
                      key: const ValueKey('image-viewer-menu-copy'),
                      leadingIcon: const Icon(AppIcons.linkSimple),
                      onPressed: () => copyImagePath(context, image.copyPath),
                      child: const Text('Copy path'),
                    ),
                    if (open != null)
                      MenuItemButton(
                        key: const ValueKey('image-viewer-menu-open'),
                        leadingIcon: const Icon(AppIcons.arrowSquareOut),
                        onPressed: () => _open(open),
                        child: const Text('Open'),
                      ),
                  ],
                  builder: (context, menu, _) => IconButton(
                    key: const ValueKey('image-viewer-more'),
                    tooltip: 'More',
                    icon: const Icon(AppIcons.dotsThree),
                    onPressed: () => menu.isOpen ? menu.close() : menu.open(),
                  ),
                ),
                close,
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: heading),
              if (zoomable) ...[
                const SizedBox(width: Insets.sm),
                _ZoomGroup(
                  controller: _zoom,
                  onZoomIn: () => _zoomBy(_zoom.zoomIn),
                  onZoomOut: () => _zoomBy(_zoom.zoomOut),
                  onFit: _fit,
                  onActual: () => _zoomBy(_zoom.actualSize),
                ),
              ],
              const SizedBox(width: Insets.sm),
              if (copyImage != null)
                TextButton.icon(
                  key: const ValueKey('image-viewer-copy-image'),
                  onPressed: copyImage,
                  icon: const Icon(AppIcons.copySimple),
                  label: const Text('Copy image'),
                ),
              TextButton.icon(
                key: const ValueKey('image-viewer-copy'),
                onPressed: () => copyImagePath(context, image.copyPath),
                icon: const Icon(AppIcons.linkSimple),
                label: const Text('Copy path'),
              ),
              if (open != null)
                TextButton.icon(
                  key: const ValueKey('image-viewer-open'),
                  onPressed: () => _open(open),
                  icon: const Icon(AppIcons.arrowSquareOut),
                  label: const Text('Open'),
                ),
              close,
            ],
          );
        },
      ),
    );
  }

  Widget _stage(
    BuildContext context,
    TranscriptImageView image,
    TranscriptImageRead? read,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final bytes = read?.bytes;
    final Widget picture;
    if (read == null) {
      picture = const Center(
        child: InlineSpinner(
          size: InlineSpinnerSize.large,
          semanticsLabel: 'Reading image',
        ),
      );
    } else if (bytes == null) {
      picture = Center(
        child: Padding(
          padding: const EdgeInsets.all(Insets.lg),
          child: TranscriptImageNote(name: image.name, note: read.note!),
        ),
      );
    } else if (image.isSvg) {
      picture = InteractiveViewer(
        maxScale: ImageViewer.maxScale,
        child: Center(
          child: SvgPicture.memory(
            bytes,
            fit: BoxFit.contain,
            semanticsLabel: image.name,
          ),
        ),
      );
    } else {
      picture = Semantics(
        image: true,
        label: image.name,
        child: ImageViewer(
          key: ValueKey('image-viewer-picture-$_index'),
          bytes: bytes,
          controller: _zoom,
          onDecoded: (size) => setState(
            () => _decoded = (
              width: size.width.round(),
              height: size.height.round(),
            ),
          ),
        ),
      );
    }
    return ColoredBox(
      // A dark ground in either theme: a lightbox, not a page.
      color: scheme.scrim,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Listener(
            onPointerDown: _pointerDown,
            onPointerUp: _pointerUp,
            onPointerCancel: (event) => _touches.remove(event.pointer),
            child: TranscriptImageActions(
              target: bytes == null ? null : image.target(bytes),
              child: picture,
            ),
          ),
          if (_count > 1) ...[
            Positioned(
              left: Insets.lg,
              top: 0,
              bottom: 0,
              child: Center(
                child: _StepButton(
                  key: const ValueKey('image-viewer-previous'),
                  tooltip: 'Previous image',
                  icon: AppIcons.caretLeft,
                  onPressed: _index > 0 ? () => _go(_index - 1) : null,
                ),
              ),
            ),
            Positioned(
              right: Insets.lg,
              top: 0,
              bottom: 0,
              child: Center(
                child: _StepButton(
                  key: const ValueKey('image-viewer-next'),
                  tooltip: 'Next image',
                  icon: AppIcons.caretRight,
                  onPressed: _index < _count - 1 ? () => _go(_index + 1) : null,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// A swipe on a touchscreen turns the page while the picture is fitted;
  /// a pinch or a zoom hands the drag back to panning.
  void _pointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    _touches.add(event.pointer);
    if (_touches.length == 1) {
      _swipeFrom = event.position;
      _pinched = false;
    } else {
      _pinched = true;
      _zoomed = true;
    }
  }

  void _pointerUp(PointerUpEvent event) {
    if (!_touches.remove(event.pointer) || _touches.isNotEmpty) return;
    final from = _swipeFrom;
    _swipeFrom = null;
    if (from == null || _pinched || _zoomed || _count < 2) return;
    final moved = event.position - from;
    if (moved.dx.abs() < Touch.target * 2 ||
        moved.dx.abs() < moved.dy.abs() * 2) {
      return;
    }
    _go(moved.dx < 0 ? _index + 1 : _index - 1);
  }

  Widget _filmstrip(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      key: const ValueKey('image-viewer-filmstrip'),
      height: Chrome.filmstripThumb + Insets.md * 2,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.lg,
          vertical: Insets.md,
        ),
        children: [
          Center(
            child: Text(
              '${_index + 1} of $_count',
              key: const ValueKey('image-viewer-position'),
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: Insets.md),
          for (var i = 0; i < _count; i++) ...[
            if (i > 0) const SizedBox(width: Insets.sm),
            _FilmstripThumb(
              key: ValueKey('image-viewer-thumb-$i'),
              image: widget.images[i],
              label: 'Image ${i + 1} of $_count, ${widget.images[i].name}',
              selected: i == _index,
              onTap: () => _go(i),
            ),
          ],
        ],
      ),
    );
  }
}

/// −, the zoom as a percentage, +, Fit and 1:1, as one group.
class _ZoomGroup extends StatelessWidget {
  const _ZoomGroup({
    required this.controller,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onFit,
    required this.onActual,
  });

  final ImageViewerController controller;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onFit;
  final VoidCallback onActual;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: const ValueKey('image-viewer-zoom-out'),
            tooltip: 'Zoom out',
            icon: const Icon(AppIcons.magnifyingGlassMinus),
            onPressed: onZoomOut,
          ),
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final percent = '${(controller.scale * 100).round()}%';
              return Semantics(
                label: 'Zoom $percent',
                excludeSemantics: true,
                child: Text(
                  percent,
                  key: const ValueKey('image-viewer-zoom'),
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              );
            },
          ),
          IconButton(
            key: const ValueKey('image-viewer-zoom-in'),
            tooltip: 'Zoom in',
            icon: const Icon(AppIcons.magnifyingGlassPlus),
            onPressed: onZoomIn,
          ),
          TextButton(
            key: const ValueKey('image-viewer-fit'),
            onPressed: onFit,
            child: const Text('Fit'),
          ),
          TextButton(
            key: const ValueKey('image-viewer-actual'),
            onPressed: onActual,
            child: Semantics(
              label: 'Actual size',
              excludeSemantics: true,
              child: const Text('1:1'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Previous or next, a round button on the dark ground.
class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    super.key,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon),
      style: IconButton.styleFrom(
        backgroundColor: scheme.surfaceContainerHigh,
        foregroundColor: scheme.onSurface,
        disabledBackgroundColor: scheme.surfaceContainer,
        fixedSize: const Size.square(Touch.target),
        minimumSize: const Size.square(Touch.target),
        maximumSize: const Size.square(Touch.target),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    );
  }
}

class _FilmstripThumb extends StatelessWidget {
  const _FilmstripThumb({
    required this.image,
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final TranscriptImageView image;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: SizedBox.square(
          dimension: Chrome.filmstripThumb,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant,
                width: selected ? 2 : 1,
              ),
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Radii.sm),
              child: ColoredBox(
                color: scheme.surfaceContainerLowest,
                child: FutureBuilder<TranscriptImageRead>(
                  future: image.read(),
                  builder: (context, snapshot) {
                    final bytes = snapshot.data?.bytes;
                    if (bytes == null) {
                      return Icon(
                        AppIcons.image,
                        size: Chrome.iconSmall,
                        color: scheme.onSurfaceVariant,
                      );
                    }
                    return transcriptPicture(
                      context,
                      image,
                      bytes,
                      fit: BoxFit.cover,
                      decodeHeight: Chrome.filmstripThumb,
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
