import 'package:xterm2/xterm.dart';

import '../domain/scrollback_limits.dart';
import 'scrollback_codec.dart';

/// A pane's parsed scrollback, handed back while nobody can see it — the
/// storage half of the ingest tiers, split out so it is testable without a PTY.
class ScrollbackPark {
  ScrollbackPark(this.terminal);

  final Terminal terminal;

  String? _parked;

  /// The encoded window held in place of the buffer, or `null` while the
  /// pane's scrollback is live.
  String? get parked => _parked;

  bool get isParked => _parked != null;

  /// Encodes the scrollback and **removes** the lines above the screen, since
  /// `trimStart` only moves an index. Does nothing while a TUI owns the screen.
  bool park() {
    if (_parked != null || terminal.isUsingAltBuffer) return false;
    _parked = encodeScrollback(
      terminal,
      maxLines: kColdScrollbackMaxLines,
      maxBytes: kColdScrollbackMaxBytes,
    );
    final lines = terminal.mainBuffer.lines;
    final above = lines.length - terminal.viewHeight;
    if (above <= 0) return false;
    lines.remove(0, above);
    return true;
  }

  /// Rebuilds a bounded recent window from the parked snapshot. The buffer is
  /// cleared first: the kept screen is also the tail of that snapshot.
  void unpark() {
    final parked = _parked;
    _parked = null;
    if (parked == null) return;
    terminal.mainBuffer.clear();
    // `clear` leaves the cursor wherever the process had it; the replay has to
    // start at the top of the buffer it is filling.
    terminal.write('\x1b[H');
    // Trailing reset: every encoded *line* opens with `ESC[0m`, but the last
    // one can leave a colour in effect, and what follows this is live process
    // output that never asked to be painted in it.
    if (parked.isNotEmpty) terminal.write('$parked\x1b[0m\r\n');
  }
}
