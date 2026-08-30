import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

/// Paints a QR code with a plain [CustomPainter] — the `qr` package is the
/// pure-Dart encoder behind qr_flutter, without dragging a widget package in.
///
/// Deliberately black-on-white in both themes: a camera wants contrast, and an
/// inverted QR is the one thing many scanners refuse. `Colors.black`/`white`
/// are the structural exceptions the token guard allows.
class QrPainter extends CustomPainter {
  QrPainter(String data)
    : _image = QrImage(
        QrCode(
          payload: QrPayload.fromString(data),
          errorCorrectLevel: QrErrorCorrectLevel.medium,
        ),
      );

  final QrImage _image;

  /// Modules of quiet zone on every side, per the QR spec.
  static const int _quiet = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final modules = _image.moduleCount + _quiet * 2;
    final cell = size.shortestSide / modules;
    final paintLight = Paint()..color = Colors.white;
    final paintDark = Paint()..color = Colors.black;

    canvas.drawRect(Offset.zero & size, paintLight);
    for (var row = 0; row < _image.moduleCount; row++) {
      for (var column = 0; column < _image.moduleCount; column++) {
        if (!_image.isDark(row, column)) continue;
        canvas.drawRect(
          Rect.fromLTWH(
            (column + _quiet) * cell,
            (row + _quiet) * cell,
            cell + 0.5, // A hair of overlap so antialiasing leaves no seams.
            cell + 0.5,
          ),
          paintDark,
        );
      }
    }
  }

  @override
  bool shouldRepaint(QrPainter oldDelegate) => false;
}
