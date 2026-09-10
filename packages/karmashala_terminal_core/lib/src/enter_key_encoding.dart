/// Makes `Shift+Enter` and `Ctrl+Enter` distinguishable from plain `Enter`,
/// which the package encodes alike. Only a **press**: a release fired twice.
library;

import 'package:xterm2/core.dart';

/// `ESC` followed by carriage return: the meta-prefixed `Enter`.
const kEscapeEnter = '\x1b\r';

/// `Ctrl+E` — *end of line* — written between a typed message and its Return,
/// so a composer reading the run as a paste does not fold the Return in.
const kEndOfLineKey = '\x05';

/// The input handler the app installs on every terminal.
class KarmashalaInputHandler implements TerminalInputHandler {
  const KarmashalaInputHandler([this.fallback = defaultInputHandler]);

  /// Consulted for everything this handler does not claim.
  final TerminalInputHandler fallback;

  @override
  String? call(TerminalKeyboardEvent event) {
    if (!_isEnter(event.key)) return fallback(event);
    // Going up is not a second keystroke — only the press is encoded.
    if (event.type == TerminalKeyEventType.release) return fallback(event);
    // No modifier: the ordinary Enter the shell expects, untouched.
    if (!event.shift && !event.ctrl && !event.alt) return fallback(event);
    if (event.ctrl) return '\x1b[13;${_modifier(event)}u';
    return kEscapeEnter;
  }

  static bool _isEnter(TerminalKey key) =>
      key == TerminalKey.enter || key == TerminalKey.numpadEnter;

  /// xterm's modifier parameter.
  static int _modifier(TerminalKeyboardEvent event) =>
      1 + (event.shift ? 1 : 0) + (event.alt ? 2 : 0) + (event.ctrl ? 4 : 0);
}
