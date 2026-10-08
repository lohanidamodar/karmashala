/// What a client typed into a pty since its last Enter, as far as the bytes
/// tell: printable text, less what Backspace took back. Cursor keys and other
/// escape sequences are skipped, so an edit made with them is not followed —
/// a caller checks the screen before trusting it.
class InputLine {
  final _text = StringBuffer();
  var _escape = _Escape.none;

  /// The text typed and not yet sent; empty when none.
  String get unsent => _text.toString();

  /// Follows [bytes] a client wrote.
  void typed(List<int> bytes) {
    for (final rune in String.fromCharCodes(bytes).runes) {
      if (_skipEscape(rune)) continue;
      switch (rune) {
        case 0x0d || 0x0a || 0x03 || 0x15:
          // Enter sends it; Ctrl+C and Ctrl+U clear it.
          _text.clear();
        case 0x7f || 0x08:
          final now = _text.toString();
          _text.clear();
          if (now.isNotEmpty) {
            _text.write(String.fromCharCodes(now.runes.toList()..removeLast()));
          }
        case 0x1b:
          _escape = _Escape.started;
        case < 0x20:
          break;
        default:
          _text.writeCharCode(rune);
      }
    }
  }

  /// Follows keys the server itself typed: its Enter sends the line too.
  void typedByServer(List<int> bytes) {
    if (bytes.contains(0x0d)) _text.clear();
  }

  /// Whether [rune] belongs to an escape sequence (`ESC [ … final`,
  /// `ESC O x`, or `ESC x`), moving through it.
  bool _skipEscape(int rune) {
    switch (_escape) {
      case _Escape.none:
        return false;
      case _Escape.started:
        _escape = rune == 0x5b
            ? _Escape.csi
            : rune == 0x4f
            ? _Escape.ss3
            : _Escape.none;
        return true;
      case _Escape.csi:
        if (rune >= 0x40 && rune <= 0x7e) _escape = _Escape.none;
        return true;
      case _Escape.ss3:
        _escape = _Escape.none;
        return true;
    }
  }
}

enum _Escape { none, started, csi, ss3 }
