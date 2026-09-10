import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:xterm2/xterm.dart';

import 'package:karmashala_media/media.dart';
import '../domain/cast_playback.dart';
import '../domain/terminal_cast.dart';

/// How a recording is framed: the canvas it is drawn on, and the window drawn
/// on that.
///
/// The chrome is what makes a recording presentable rather than a screenshot of
/// a rectangle, and it is *fixed*: padding, corner radius and title-bar height
/// are the three numbers a settings screen would offer and nobody would ever
/// change. The theme and font are the app's own.
class CastFrameStyle {
  const CastFrameStyle({
    required this.width,
    required this.height,
    required this.theme,
    required this.fontFamily,
    this.title,
    this.padding = 40,
    this.cornerRadius = 10,
    this.titleBarHeight = 30,
  });

  /// 1920x1080, for the frame sequence an MP4 is cut from.
  factory CastFrameStyle.fullHd({
    required TerminalTheme theme,
    required String fontFamily,
    String? title,
  }) => CastFrameStyle(
    width: 1920,
    height: 1080,
    theme: theme,
    fontFamily: fontFamily,
    title: title,
    padding: 64,
  );

  /// 960x540 — a quarter of the pixels, because a GIF pays for every one of
  /// them in a 256-colour palette and LZW.
  factory CastFrameStyle.gif({
    required TerminalTheme theme,
    required String fontFamily,
    String? title,
  }) => CastFrameStyle(
    width: 960,
    height: 540,
    theme: theme,
    fontFamily: fontFamily,
    title: title,
  );

  final int width;
  final int height;
  final TerminalTheme theme;
  final String fontFamily;

  /// What the window's title bar says. The pane's title.
  final String? title;

  final double padding;
  final double cornerRadius;
  final double titleBarHeight;
}

/// The font size the grid is laid out at before it is scaled to fit. Only the
/// ratio matters: Skia rasterises the glyphs at the transformed size, so text
/// stays crisp at any resolution, and a middling size keeps that scale factor
/// near one for an ordinary 80x24.
const double _kLayoutFontSize = 14;

/// Replays a cast into an offscreen terminal and paints each frame.
///
/// **Runs on the isolate that owns the Flutter engine, and has to**:
/// `Picture.toImage` rasterises on the engine's raster thread and there is no
/// second engine to hand this to. The cost is bounded three ways — the painter
/// and its caches are built once and reused, each frame awaits `toImage` and so
/// yields the event loop back to the app, and everything after the pixels exist
/// happens behind [FrameSink] on a worker isolate.
class CastFrameRenderer {
  CastFrameRenderer({
    required this.cast,
    required this.style,
    this.frameRate = kRecordingFrameRate,
    this.idleCap = kCastIdleCap,
  });

  final TerminalCast cast;
  final CastFrameStyle style;
  final int frameRate;
  final Duration idleCap;

  /// Renders every frame into [sink] and closes it. [onProgress] is called with
  /// `(rendered, total)` after each frame — the only honest progress there is,
  /// because the number of frames is known before the first one is drawn and
  /// how long each takes is not.
  Future<FrameSinkResult> renderTo(
    FrameSink sink, {
    void Function(int rendered, int total)? onProgress,
    bool Function()? cancelled,
  }) async {
    final playback = planCastPlayback(
      cast,
      frameRate: frameRate,
      idleCap: idleCap,
    );
    final grid = cast.widestGrid;

    // maxLines is the grid's own height: a recording is a viewport, and keeping
    // scrollback here would only make `buffer.lines` an index puzzle.
    final terminal = Terminal(maxLines: grid.rows)
      ..resize(cast.columns, cast.rows);

    final painter = TerminalPainter(
      theme: style.theme,
      textStyle: TerminalStyle(
        fontSize: _kLayoutFontSize,
        fontFamily: style.fontFamily,
      ),
      textScaler: TextScaler.noScaling,
    );
    // Read before anything else touches the painter: the font probe is lazy and
    // sets the run-batching flag as a side effect.
    final cell = painter.cellSize;

    final layout = _WindowLayout.of(style, grid, cell);

    try {
      for (final step in playback.steps) {
        if (cancelled?.call() ?? false) {
          await sink.abort();
          throw const CastRenderCancelled();
        }
        for (final event in step.events) {
          switch (event.kind) {
            case CastEventKind.output:
              terminal.write(event.data);
            case CastEventKind.resize:
              final resized = event.grid;
              if (resized != null) {
                terminal.resize(resized.columns, resized.rows);
              }
          }
        }
        final image = await _paint(terminal, painter, layout);
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        image.dispose();
        if (bytes == null) throw StateError('frame did not rasterise');
        await sink.addFrame(
          RgbaFrame(
            rgba: bytes.buffer.asUint8List(),
            width: style.width,
            height: style.height,
            hold: step.hold,
          ),
        );
        onProgress?.call(step.index + 1, playback.frameCount);
      }
      return await sink.close();
    } finally {
      painter.dispose();
    }
  }

  Future<ui.Image> _paint(
    Terminal terminal,
    TerminalPainter painter,
    _WindowLayout layout,
  ) async {
    // Once per frame, without exception: the painter refills a per-frame
    // paragraph-layout budget here, and a painter that stops being told a frame
    // began batches its first screenful and then falls back forever.
    painter.beginFrame();

    final bounds = Rect.fromLTWH(
      0,
      0,
      style.width.toDouble(),
      style.height.toDouble(),
    );
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, bounds);
    layout.paintChrome(canvas, style, painter);

    canvas.save();
    canvas.clipRRect(layout.screenClip);
    canvas.translate(layout.screen.left, layout.screen.top);
    canvas.scale(layout.scale);
    final lines = terminal.buffer.lines;
    final rows = terminal.viewHeight < lines.length
        ? terminal.viewHeight
        : lines.length;
    for (var i = 0; i < rows; i++) {
      painter.paintLine(canvas, Offset(0, i * layout.cell.height), lines[i]);
    }
    canvas.restore();

    final picture = recorder.endRecording();
    final image = await picture.toImage(style.width, style.height);
    picture.dispose();
    return image;
  }
}

/// Thrown out of [CastFrameRenderer.renderTo] when the caller asked it to stop.
class CastRenderCancelled implements Exception {
  const CastRenderCancelled();

  @override
  String toString() => 'the render was cancelled';
}

/// Where the window sits on the frame, and how much the grid is scaled to fit.
class _WindowLayout {
  const _WindowLayout({
    required this.window,
    required this.screen,
    required this.screenClip,
    required this.scale,
    required this.cell,
  });

  factory _WindowLayout.of(
    CastFrameStyle style,
    ({int columns, int rows}) grid,
    Size cell,
  ) {
    final window = Rect.fromLTWH(
      style.padding,
      style.padding,
      style.width - style.padding * 2,
      style.height - style.padding * 2,
    );
    // The grid gets whatever the title bar leaves, minus a hair of inset so
    // glyphs do not touch the window's edge.
    const inset = 10.0;
    final screen = Rect.fromLTWH(
      window.left + inset,
      window.top + style.titleBarHeight,
      window.width - inset * 2,
      window.height - style.titleBarHeight - inset,
    );
    // One scale for both axes: a grid stretched to fill would no longer be a
    // terminal. Capped at 1 so a small grid is drawn at its laid-out size and
    // centred rather than blown up into a poster.
    final byWidth = screen.width / (cell.width * grid.columns);
    final byHeight = screen.height / (cell.height * grid.rows);
    final scale = (byWidth < byHeight ? byWidth : byHeight).clamp(0.05, 1.0);
    final drawn = Size(
      cell.width * grid.columns * scale,
      cell.height * grid.rows * scale,
    );
    final centred = Rect.fromLTWH(
      screen.left + (screen.width - drawn.width) / 2,
      screen.top,
      drawn.width,
      drawn.height,
    );
    return _WindowLayout(
      window: window,
      screen: centred,
      screenClip: RRect.fromRectAndRadius(
        screen,
        Radius.circular(style.cornerRadius / 2),
      ),
      scale: scale,
      cell: cell,
    );
  }

  final Rect window;

  /// Where the grid's top-left corner goes, already centred.
  final Rect screen;
  final RRect screenClip;
  final double scale;
  final Size cell;

  /// The ground, the window, its title bar and its title.
  void paintChrome(Canvas canvas, CastFrameStyle style, TerminalPainter painter) {
    final theme = style.theme;
    // A ground a shade off the terminal's own, so the window has an edge
    // without a border being drawn round it.
    canvas.drawRect(
      Rect.fromLTWH(0, 0, style.width.toDouble(), style.height.toDouble()),
      Paint()..color = _shade(theme.background, 0.55),
    );
    final rounded = RRect.fromRectAndRadius(
      window,
      Radius.circular(style.cornerRadius),
    );
    canvas.drawRRect(rounded, Paint()..color = theme.background);
    canvas.drawRRect(
      rounded,
      Paint()
        ..color = _shade(theme.foreground, 0.18)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    final dotY = window.top + style.titleBarHeight / 2;
    final radius = style.titleBarHeight * 0.16;
    for (var i = 0; i < 3; i++) {
      canvas.drawCircle(
        Offset(window.left + style.titleBarHeight * (0.7 + i * 0.55), dotY),
        radius,
        Paint()..color = [theme.red, theme.yellow, theme.green][i],
      );
    }

    final title = style.title;
    if (title == null || title.isEmpty) return;
    final label = TextPainter(
      text: TextSpan(
        text: title,
        style: TextStyle(
          color:
              Color.lerp(theme.foreground, theme.background, 0.35) ??
              theme.foreground,
          fontSize: style.titleBarHeight * 0.45,
          fontFamily: style.fontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: window.width * 0.6);
    label.paint(
      canvas,
      Offset(
        window.left + (window.width - label.width) / 2,
        dotY - label.height / 2,
      ),
    );
    label.dispose();
  }
}

/// [color] scaled towards black by [amount], keeping its alpha.
Color _shade(Color color, double amount) => Color.from(
  alpha: color.a,
  red: color.r * amount,
  green: color.g * amount,
  blue: color.b * amount,
);
