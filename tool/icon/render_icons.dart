/// Draws the application icon and its Android adaptive layers.
///
/// Rendered rather than traced: one description of the mark produces the badge,
/// the adaptive foreground and background, and the themed monochrome glyph, so
/// the layers cannot drift the way derived-from-PNG layers do.
///
///   flutter test tool/icon/render_icons.dart
///   dart run flutter_launcher_icons
///
/// The mark is Chitragupta's ledger read as a terminal: three closed records
/// above, and the live line — a prompt and its cursor — in the one accent the
/// app allows itself.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Neutral field, matching the desktop chrome rather than a brand colour.
const _fieldTop = Color(0xFF171A22);
const _fieldBottom = Color(0xFF232837);

/// The recorded lines: present, quiet, never competing with the prompt.
const _rule = Color(0xFF39415A);

/// `AppColors.accentDark` — the one accent, and the only saturated thing here.
const _accent = Color(0xFF7AA2F7);

const double _size = 1024;

void main() {
  test('renders the icon and its adaptive layers', () async {
    await _write('assets/icon/app_icon.png', (canvas) {
      _field(canvas, rounded: true);
      _mark(canvas);
    });
    // Full-bleed: flutter_launcher_icons insets the foreground by 16%, which
    // is the adaptive safe zone, so the mark must not be pre-shrunk.
    await _write('assets/icon/app_icon_foreground.png', _mark);
    await _write(
      'assets/icon/app_icon_background.png',
      (canvas) => _field(canvas, rounded: false),
    );
    // Android tints this by the wallpaper, so it carries the mark alone.
    await _write(
      'assets/icon/app_icon_monochrome.png',
      (canvas) => _mark(canvas, monochrome: true),
    );
    // The tray, where the icon is 16px and shares a bar with everything else:
    // the badge again, and the same badge wearing the attention dot.
    await _write('assets/icon/tray_source.png', (canvas) {
      _field(canvas, rounded: true);
      _mark(canvas);
    });
    await _write('assets/icon/tray_source_attention.png', (canvas) {
      _field(canvas, rounded: true);
      _mark(canvas);
      _attentionDot(canvas);
    });
  });
}

/// The badge: a neutral gradient, squared off for the adaptive background and
/// rounded for every platform that shows the icon as drawn.
void _field(Canvas canvas, {required bool rounded}) {
  final rect = const Rect.fromLTWH(0, 0, _size, _size);
  final paint = Paint()
    ..shader = const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [_fieldTop, _fieldBottom],
    ).createShader(rect);
  if (rounded) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(_size * 0.225)),
      paint,
    );
  } else {
    canvas.drawRect(rect, paint);
  }
}

/// Three closed records, then the live line: `>` and its cursor.
void _mark(Canvas canvas, {bool monochrome = false}) {
  // The drawing below is measured from its own top-left. Lift it onto the
  // optical centre, then fill more of the tile — at 32px, a mark that only
  // covered half the icon read as a smudge.
  canvas.translate(_size / 2, _size / 2);
  canvas.scale(1.18);
  canvas.translate(-_size / 2, -_size / 2);
  canvas.translate(0, -52);
  final ruleColor = monochrome ? Colors.white.withValues(alpha: 0.55) : _rule;
  final accent = monochrome ? Colors.white : _accent;

  final rulePaint = Paint()
    ..color = ruleColor
    ..strokeWidth = 26
    ..strokeCap = StrokeCap.round;
  // Shortening each line downwards leaves the eye travelling toward the
  // prompt instead of stopping at a block of equal bars.
  const widths = [520.0, 440.0, 360.0];
  for (var i = 0; i < widths.length; i++) {
    final y = 330 + i * 84.0;
    canvas.drawLine(Offset(268, y), Offset(268 + widths[i], y), rulePaint);
  }

  final promptPaint = Paint()
    ..color = accent
    ..style = PaintingStyle.stroke
    ..strokeWidth = 62
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  canvas.drawPath(
    Path()
      ..moveTo(276, 596)
      ..lineTo(392, 690)
      ..lineTo(276, 784),
    promptPaint,
  );

  // The cursor: a filled bar on the prompt's baseline, the one solid shape.
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      const Rect.fromLTWH(452, 754, 304, 46),
      const Radius.circular(23),
    ),
    Paint()..color = accent,
  );
}

/// The waiting-on-you badge: one dot, in the semantic colour, sized to survive
/// a 16px tray — it is the only thing that must read at that size.
void _attentionDot(Canvas canvas) {
  const center = Offset(_size * 0.71, _size * 0.29);
  canvas.drawCircle(center, _size * 0.20, Paint()..color = _fieldTop);
  canvas.drawCircle(
    center,
    _size * 0.155,
    Paint()..color = const Color(0xFFE5484D),
  );
}

Future<void> _write(String path, void Function(Canvas) paint) async {
  final recorder = ui.PictureRecorder();
  paint(Canvas(recorder));
  final image = await recorder.endRecording().toImage(
    _size.toInt(),
    _size.toInt(),
  );
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  File(path).writeAsBytesSync(data!.buffer.asUint8List());
}
