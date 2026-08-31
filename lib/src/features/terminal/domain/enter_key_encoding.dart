/// Makes `Shift+Enter` and `Ctrl+Enter` distinguishable from plain `Enter`.
///
/// A terminal encodes `Enter` as a bare carriage return, and the vendored
/// package encodes **every** modified `Enter` the same way. Measured against
/// `xterm 4.0.0`'s default keytab, `Enter`, `Shift+Enter`, `Ctrl+Enter`,
/// `Alt+Enter` and `Ctrl+Shift+Enter` all produce exactly `0x0D` — so a program
/// running in the pane cannot tell them apart, which is why Claude Code's
/// "insert a newline instead of submitting" chords do nothing here: `Shift+Enter`
/// arrives as the same byte as the submit key.
///
/// Two encodings, chosen for what programs actually read:
///
/// * **`ESC CR` (`\x1b\r`)** for anything modified that is not `Ctrl`. This is
///   the traditional meta prefix — `ESC` followed by the unmodified key — and
///   it is exactly the sequence Claude Code's own iTerm2 and VS Code setup binds
///   `Shift+Enter` to, so it works with no configuration at either end.
///   `Alt+Enter` produces the same bytes, which is correct rather than
///   unfortunate: `ESC`-prefixing *is* what Alt means to a terminal.
/// * **CSI-u (`CSI 13 ; <modifier> u`)** whenever `Ctrl` is held. `Ctrl+Enter`
///   has no historical encoding to inherit, and CSI-u is the sequence xterm's
///   `modifyOtherKeys` and the kitty keyboard protocol both use, so a program
///   that understands modifier reporting reads the modifiers correctly. One that
///   does not ignores an unknown CSI, which is the safe way to be wrong — far
///   better than `\r`, which submits.
///
/// The modifier parameter is xterm's: `1 + shift(1) + alt(2) + ctrl(4)`.
///
/// **Plain `Enter` is not touched at all** — it stays `0x0D`, and so does the
/// `\r\n` the package emits under line-feed mode — because this only intervenes
/// when a modifier is actually held.
///
/// Like [ChitraguptaMouseHandler], this lives here rather than in the vendored
/// package: `Terminal.inputHandler` is injectable, so correcting the encoding
/// costs no divergence. Everything that is not a modified `Enter` is delegated
/// straight back to the package's own handler.
///
/// **Not implemented, deliberately:** honouring `modifyOtherKeys`
/// (`CSI > 4 ; 2 m`) or the kitty protocol (`CSI > 1 u`) so the *program* chooses
/// when modifiers are reported. That needs the vendored parser to route prefixed
/// CSI away from SGR, a new `EscapeHandler` method, and mode state on `Terminal`
/// — three forked files — and it would not change the reported symptom, because
/// `ESC CR` already works with Claude Code unconfigured. See
/// `docs/loop-reports/loop-84.md`.
library;

import 'package:xterm/core.dart';

/// `ESC` followed by carriage return: the meta-prefixed `Enter`.
const kEscapeEnter = '\x1b\r';

/// The input handler the app installs on every terminal.
class ChitraguptaInputHandler implements TerminalInputHandler {
  const ChitraguptaInputHandler([this.fallback = defaultInputHandler]);

  /// Consulted for everything this handler does not claim.
  final TerminalInputHandler fallback;

  @override
  String? call(TerminalKeyboardEvent event) {
    if (!_isEnter(event.key)) return fallback(event);
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
