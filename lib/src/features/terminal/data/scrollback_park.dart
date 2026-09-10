import 'package:xterm2/xterm.dart';

import '../domain/scrollback_limits.dart';
import 'scrollback_codec.dart';

/// A pane's parsed scrollback, handed back while nobody can see it.
///
/// The storage half of the ingest tiers — see [kColdScrollbackMaxLines] for
/// what a detached pane's full buffer was costing. Split out of the pane so the
/// mechanism can be tested without a PTY, and so there is one implementation of
/// it rather than one per kind of instance.
class ScrollbackPark {
  ScrollbackPark(this.terminal);

  final Terminal terminal;

  String? _parked;

  /// The encoded window held in place of the buffer, or `null` while the
  /// pane's scrollback is live.
  String? get parked => _parked;

  bool get isParked => _parked != null;

  /// Encodes the scrollback and releases the lines above the screen. Returns
  /// whether anything was released, which decides whether the command blocks
  /// anchored to those lines are dropped.
  ///
  /// The lines are **removed** rather than trimmed: `trimStart` only moves the
  /// circular buffer's start index, so every `BufferLine` stays reachable from
  /// the backing array. Does nothing while a full-screen program owns the
  /// display — a snapshot cannot be written back underneath one — which is also
  /// how `ColdScreen` knows to leave a TUI alone.
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

  /// Rebuilds a bounded recent window from the parked snapshot. The kept screen
  /// is also the tail of that snapshot, so the buffer is cleared before the
  /// replay: the window is written once, in order, rather than appended below a
  /// copy of its own last page.
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
