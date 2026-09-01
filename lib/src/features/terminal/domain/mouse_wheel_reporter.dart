/// Corrects the mouse-wheel button codes xterm 4.0.0 reports.
///
/// `TerminalMouseButton` in the vendored package gives the wheel buttons ids
/// `64 + 4 = 68` and `64 + 5 = 69`. The xterm control-sequence spec says wheel
/// buttons are *buttons 4-7 transposed into bit 6* — that is, wheel up is
/// `64 + 0 = 64`, wheel down `64 + 1 = 65`, and horizontal `66`/`67`. The
/// package's own doc comment describes the transposition correctly; the
/// constants simply add 64 instead of applying it.
///
/// The four spare bits matter: bit 2 (value 4) is the **Shift** modifier. So
/// `68` reads as Shift+WheelUp, and no default tmux binding matches that, which
/// is why a terminal running tmux with `set -g mouse on` would not scroll.
///
/// Verified against real tmux 3.7b: sending `CSI < 64 ; x ; y M` puts the pane
/// into copy-mode (it scrolls); sending `CSI < 68 ; x ; y M` does nothing.
///
/// This lives in our code rather than in the vendored package because
/// `Terminal.mouseHandler` is injectable, so the fix costs no divergence. Only
/// the wheel is reimplemented — every other button is delegated straight back to
/// the package's own handler, which is correct.
library;

import 'package:xterm/core.dart';

/// Wheel button ids per the xterm spec, keyed by the package's enum.
const _wheelIds = <TerminalMouseButton, int>{
  TerminalMouseButton.wheelUp: 64,
  TerminalMouseButton.wheelDown: 65,
  TerminalMouseButton.wheelLeft: 66,
  TerminalMouseButton.wheelRight: 67,
};

/// The mouse handler the app installs on every terminal.
class KarmashalaMouseHandler implements TerminalMouseHandler {
  const KarmashalaMouseHandler();

  @override
  String? call(TerminalMouseEvent event) {
    final wheelId = _wheelIds[event.button];
    if (wheelId == null) return defaultMouseHandler(event);

    // A wheel "release" is not a thing; upstream drops it and so do we.
    if (event.buttonState == TerminalMouseButtonState.up) return null;

    switch (event.state.mouseMode) {
      case MouseMode.none:
      case MouseMode.clickOnly:
        // The application is not asking for wheel reports. Returning null lets
        // TerminalView fall back to simulating arrow keys, which is what makes
        // `less`, `man` and a default-configured tmux scroll at all.
        return null;
      case MouseMode.upDownScroll:
      case MouseMode.upDownScrollDrag:
      case MouseMode.upDownScrollMove:
        break;
    }

    // Coordinates are reported 1-based.
    final x = event.position.x + 1;
    final y = event.position.y + 1;

    switch (event.state.mouseReportMode) {
      case MouseReportMode.sgr:
        return '\x1b[<$wheelId;$x;${y}M';
      case MouseReportMode.urxvt:
        return '\x1b[${32 + wheelId};$x;${y}M';
      case MouseReportMode.normal:
      case MouseReportMode.utf:
        final limit = event.state.mouseReportMode == MouseReportMode.normal
            ? 223
            : 2015;
        String coord(int value) =>
            value > limit ? '\x00' : String.fromCharCode(32 + value);
        return '\x1b[M${String.fromCharCode(32 + wheelId)}'
            '${coord(x)}${coord(y)}';
    }
  }
}
