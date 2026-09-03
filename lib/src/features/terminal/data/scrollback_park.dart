import 'package:xterm2/xterm.dart';

import '../domain/scrollback_limits.dart';
import 'scrollback_codec.dart';

/// A pane's parsed scrollback, handed back while nobody can see it.
///
/// The storage half of the ingest tiers. A detached pane kept the same
/// [kLiveScrollbackMaxLines] buffer as a visible one — `BufferLine`s of four
/// 32-bit words per cell — for a view nobody has and, since visibility-aware
/// ingestion landed, with nothing writing into it either. See
/// [kColdScrollbackMaxLines] for the measurement.
///
/// Split out of the pane so the mechanism can be tested without a PTY, and so
/// there is one implementation of it rather than one per kind of instance.
class ScrollbackPark {
  ScrollbackPark(this.terminal);

  final Terminal terminal;

  String? _parked;

  /// The encoded window held in place of the buffer, or `null` while the
  /// pane's scrollback is live.
  String? get parked => _parked;

  bool get isParked => _parked != null;

  /// Encodes the scrollback and releases the lines above the screen.
  ///
  /// Returns whether anything was released, which the caller uses to decide
  /// whether to drop the command blocks anchored to those lines.
  ///
  /// The lines are **removed** rather than trimmed: `trimStart` only moves the
  /// circular buffer's start index, leaving every `BufferLine` reachable from
  /// the backing array — which for a pane that has stopped producing output
  /// means never overwritten and never freed.
  ///
  /// The screen stays, and costs nothing: a buffer can never hold fewer lines
  /// than its viewport. Keeping it is what lets `terminalTailLines` still read
  /// a detached session's last screen, so a background session does not go dark
  /// for the status sources merely because nobody is looking at it.
  ///
  /// Does nothing while a full-screen program owns the display. The alternate
  /// buffer is bounded to the viewport already, and there is no way to write a
  /// snapshot back into the main buffer while the alternate one is in front —
  /// so such a pane keeps history it could not otherwise restore. [isParked] is
  /// therefore also how `ColdScreen` knows to leave a TUI alone: its screen is
  /// redrawn by the reattach replay, and a half-applied redraw underneath that
  /// would only be applied twice.
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

  /// Rebuilds a bounded recent window from the parked snapshot.
  ///
  /// The kept screen is also the tail of that snapshot, so the buffer is
  /// cleared before the replay: the window is written once, in order, rather
  /// than appended below a copy of its own last page.
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
