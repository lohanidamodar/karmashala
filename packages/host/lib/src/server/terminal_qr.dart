import 'package:qr/qr.dart';

/// [data] as a QR code a phone can scan off a terminal: two module rows per
/// text row, drawn with Unicode half blocks, and a quiet zone of four modules
/// on every side, as the spec asks.
///
/// With [ansi] (the default) the code is drawn black on white whatever the
/// terminal's colours — many scanners refuse an inverted code, and a dark
/// terminal would otherwise invert it. Without, the blocks are the terminal's
/// foreground on its background: right for a light terminal or a file.
///
/// Secret for a pairing QR: print it for the person, never log it.
String terminalQr(String data, {bool ansi = true}) {
  final image = QrImage(
    QrCode(
      payload: QrPayload.fromString(data),
      errorCorrectLevel: QrErrorCorrectLevel.low,
    ),
  );
  const quiet = 4;
  final size = image.moduleCount + quiet * 2;
  bool dark(int row, int column) {
    final r = row - quiet;
    final c = column - quiet;
    if (r < 0 || c < 0 || r >= image.moduleCount || c >= image.moduleCount) {
      return false;
    }
    return image.isDark(r, c);
  }

  final out = StringBuffer();
  for (var row = 0; row < size; row += 2) {
    if (ansi) out.write('\x1b[30;47m');
    for (var column = 0; column < size; column++) {
      final top = dark(row, column);
      final bottom = row + 1 < size && dark(row + 1, column);
      out.write(switch ((top, bottom)) {
        (true, true) => '█',
        (true, false) => '▀',
        (false, true) => '▄',
        (false, false) => ' ',
      });
    }
    if (ansi) out.write('\x1b[0m');
    out.writeln();
  }
  return out.toString();
}
