import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// What the toolbar asks of an [ImageViewer]: fit it, show it pixel for pixel,
/// or step the zoom. Notifies when the scale changes, so a label can follow.
class ImageViewerController extends ChangeNotifier {
  _ImageViewerState? _view;

  /// Logical pixels per image pixel now; 1 before the image is placed.
  double get scale => _view?._scale ?? 1;

  void fit() => _view?._place(_Placement.fit);

  void actualSize() => _view?._place(_Placement.actual);

  void zoomIn() => _view?._zoomBy(_step);

  void zoomOut() => _view?._zoomBy(1 / _step);

  static const _step = 1.25;

  void _changed() => notifyListeners();
}

/// How the picture sits in the pane until someone pans or zooms it by hand;
/// a resize keeps it there. [free] is "where the reader left it".
enum _Placement { auto, fit, actual, free }

/// One image, pannable and zoomable: Ctrl+wheel, the wheel and a pinch zoom
/// about the pointer, a drag pans. It opens fitted to the pane, or at 100%
/// when that is smaller. New [bytes] for the same file keep the reader's
/// zoom and position — a re-rendered screenshot is compared, not re-found.
class ImageViewer extends StatefulWidget {
  const ImageViewer({
    required this.bytes,
    required this.controller,
    this.onDecoded,
    this.onFailed,
    super.key,
  });

  final Uint8List bytes;
  final ImageViewerController controller;

  /// The image's size in pixels, once it decodes.
  final ValueChanged<Size>? onDecoded;

  /// The bytes are not an image Flutter can decode.
  final VoidCallback? onFailed;

  static const minScale = 0.02;
  static const maxScale = 32.0;

  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer> {
  final _transform = TransformationController();
  ImageStream? _stream;
  ImageStreamListener? _listener;

  /// The decoded size, in image pixels; null until the first frame.
  Size? _image;
  Size _viewport = Size.zero;
  _Placement _placement = _Placement.auto;

  double get _scale => _transform.value.getMaxScaleOnAxis();

  @override
  void initState() {
    super.initState();
    widget.controller._view = this;
    _transform.addListener(widget.controller._changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_stream == null) _resolve();
  }

  @override
  void didUpdateWidget(ImageViewer old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      _transform.removeListener(old.controller._changed);
      if (old.controller._view == this) old.controller._view = null;
      widget.controller._view = this;
      _transform.addListener(widget.controller._changed);
    }
    if (!identical(old.bytes, widget.bytes)) _resolve();
  }

  @override
  void dispose() {
    _unlisten();
    _transform.removeListener(widget.controller._changed);
    if (widget.controller._view == this) widget.controller._view = null;
    _transform.dispose();
    super.dispose();
  }

  void _unlisten() {
    if (_listener case final listener?) _stream?.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  /// Decodes beside `Image.memory` — the same [MemoryImage], so one decode —
  /// for the size that placing and the status line need.
  void _resolve() {
    _unlisten();
    final stream = MemoryImage(
      widget.bytes,
    ).resolve(createLocalImageConfiguration(context));
    var reported = false;
    final listener = ImageStreamListener(
      (info, _) {
        final size = Size(
          info.image.width.toDouble(),
          info.image.height.toDouble(),
        );
        info.dispose();
        // An animation calls back every frame; only its first is news.
        if (reported) return;
        reported = true;
        // A cached image answers inside `resolve`, mid-build, where the
        // parent's setState would throw; the microtask runs after the frame.
        scheduleMicrotask(() {
          if (!mounted || stream != _stream) return;
          widget.onDecoded?.call(size);
          if (size == _image) return;
          setState(() => _image = size);
          _placeAfterLayout();
        });
      },
      onError: (_, _) => scheduleMicrotask(() {
        if (mounted && stream == _stream) widget.onFailed?.call();
      }),
    );
    stream.addListener(listener);
    _stream = stream;
    _listener = listener;
  }

  void _placeAfterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _apply();
    });
  }

  void _place(_Placement placement) {
    _placement = placement;
    _apply();
  }

  /// Puts the picture where [_placement] says, centred. A no-op for [free].
  void _apply() {
    final image = _image;
    if (image == null || _viewport.isEmpty || image.isEmpty) return;
    final fit = math.min(
      _viewport.width / image.width,
      _viewport.height / image.height,
    );
    final scale = switch (_placement) {
      _Placement.auto => math.min(1.0, fit),
      _Placement.fit => fit,
      _Placement.actual => 1.0,
      _Placement.free => null,
    };
    if (scale == null) return;
    final s = scale.clamp(ImageViewer.minScale, ImageViewer.maxScale);
    _transform.value = Matrix4.identity()
      ..translateByDouble(
        (_viewport.width - image.width * s) / 2,
        (_viewport.height - image.height * s) / 2,
        0,
        1,
      )
      ..scaleByDouble(s, s, 1, 1);
  }

  /// Steps the zoom about the pane's centre, where a toolbar click means.
  void _zoomBy(double factor) {
    if (_image == null || _viewport.isEmpty) return;
    final now = _scale;
    final next = (now * factor).clamp(
      ImageViewer.minScale,
      ImageViewer.maxScale,
    );
    if (next == now) return;
    final centre = _viewport.center(Offset.zero);
    final scene = _transform.toScene(centre);
    final k = next / now;
    _placement = _Placement.free;
    _transform.value = _transform.value.clone()
      ..translateByDouble(scene.dx, scene.dy, 0, 1)
      ..scaleByDouble(k, k, 1, 1)
      ..translateByDouble(-scene.dx, -scene.dy, 0, 1);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.biggest;
        if (viewport != _viewport) {
          _viewport = viewport;
          // A split dragged or a window resized: a placed picture stays placed.
          _placeAfterLayout();
        }
        final image = _image;
        return ClipRect(
          child: InteractiveViewer(
            transformationController: _transform,
            constrained: false,
            boundaryMargin: const EdgeInsets.all(double.infinity),
            minScale: ImageViewer.minScale,
            maxScale: ImageViewer.maxScale,
            onInteractionStart: (_) => _placement = _Placement.free,
            child: SizedBox(
              width: image?.width ?? viewport.width,
              height: image?.height ?? viewport.height,
              child: image == null
                  ? const SizedBox.shrink()
                  : CustomPaint(
                      painter: _Checkerboard(
                        transform: _transform,
                        viewport: viewport,
                        light: scheme.surfaceContainerHigh,
                        dark: scheme.surfaceContainerHighest,
                      ),
                      child: Image.memory(
                        widget.bytes,
                        fit: BoxFit.fill,
                        gaplessPlayback: true,
                        filterQuality: FilterQuality.medium,
                        // The listener above reports a failure; this keeps the
                        // frame blank rather than drawing Flutter's error box.
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
            ),
          ),
        );
      },
    );
  }
}

/// The squares behind a transparent image, a constant size on screen however
/// far it is zoomed. Only the squares inside [viewport] are drawn: a large
/// image at 100% would otherwise be a hundred thousand of them a frame.
class _Checkerboard extends CustomPainter {
  _Checkerboard({
    required this.transform,
    required this.viewport,
    required this.light,
    required this.dark,
  }) : super(repaint: transform);

  final TransformationController transform;
  final Size viewport;
  final Color light;
  final Color dark;

  static const _square = 8.0;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRect(bounds, Paint()..color = light);
    final scale = transform.value.getMaxScaleOnAxis();
    if (scale <= 0) return;
    final cell = _square / scale;
    final visible = Rect.fromPoints(
      transform.toScene(Offset.zero),
      transform.toScene(viewport.bottomRight(Offset.zero)),
    ).intersect(bounds);
    if (visible.isEmpty) return;
    final firstColumn = (visible.left / cell).floor();
    final lastColumn = (visible.right / cell).ceil();
    final firstRow = (visible.top / cell).floor();
    final lastRow = (visible.bottom / cell).ceil();
    final path = Path();
    for (var row = firstRow; row < lastRow; row++) {
      for (var column = firstColumn; column < lastColumn; column++) {
        if ((row + column).isEven) continue;
        path.addRect(Rect.fromLTWH(column * cell, row * cell, cell, cell));
      }
    }
    canvas.clipRect(bounds);
    canvas.drawPath(path, Paint()..color = dark);
  }

  @override
  bool shouldRepaint(_Checkerboard old) =>
      old.light != light ||
      old.dark != dark ||
      old.viewport != viewport ||
      old.transform != transform;
}
