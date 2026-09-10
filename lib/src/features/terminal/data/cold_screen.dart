import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:xterm2/xterm.dart';

import '../domain/ingest_tier.dart';
import 'scrollback_park.dart';
import 'scrollback_spool.dart';
import 'terminal_ingest_budget.dart';

/// How far behind its process a detached pane's screen may fall. One second,
/// the order the status pipeline works at: shorter would buy nothing anybody
/// could act on, longer would let an approval prompt sit unnoticed.
const Duration kColdScreenRefreshInterval = Duration(seconds: 1);

/// Bytes a cold pane holds for its screen before the oldest are dropped.
/// Several screens' worth, and deliberately far smaller than
/// [kScrollbackSpoolMaxBytes]: the spool has to replay what the user missed,
/// this only has to draw the last screen of it.
const int kColdScreenPendingMaxBytes = 32 * 1024;

/// Keeps a detached pane's *screen* current while its scrollback stays parked.
///
/// `terminalTailLines` reads the bottom of the grid to tell whether an agent is
/// waiting for approval, and a session with no tab is exactly the one nobody is
/// watching — left alone, its status froze when it was detached. The cost is
/// kept to the screen: one parse per [kColdScreenRefreshInterval] at most, out
/// of the shared pool, driven by bytes arriving rather than by a timer. It
/// refreshes whatever buffer the pane draws into, the alternate one included.
class ColdScreen {
  ColdScreen({
    required this.terminal,
    required this.park,
    TerminalIngestBudget? budget,
    IngestClock? clock,
    this.refreshInterval = kColdScreenRefreshInterval,
    int maxPendingBytes = kColdScreenPendingMaxBytes,
  }) : _budget = budget ?? terminalIngestBudget,
       _clock = clock ?? _defaultClock,
       _pending = ScrollbackSpool(maxBytes: maxPendingBytes) {
    _decoderSink = const Utf8Decoder(
      allowMalformed: true,
    ).startChunkedConversion(_CallbackSink(_decoded.write));
  }

  final Terminal terminal;

  /// The pane's parked scrollback, read only by [_trimToScreen]: giving lines
  /// back is meaningful for a pane that gave lines up, and for no other.
  final ScrollbackPark park;

  final Duration refreshInterval;
  final TerminalIngestBudget _budget;
  final IngestClock _clock;
  final ScrollbackSpool _pending;

  final _decoded = StringBuffer();
  late final ByteConversionSink _decoderSink;

  Duration? _refreshedAt;
  int _refreshes = 0;

  /// How many times the screen has been redrawn. Diagnostics, and what the
  /// tests assert on: a refresh that stopped happening looks like a quiet pane.
  int get refreshes => _refreshes;

  /// Bytes held for the screen but not yet parsed.
  @visibleForTesting
  int get pendingBytes => _pending.length;

  /// Queues process output and redraws the screen if an interval has passed.
  void add(Uint8List bytes) {
    if (bytes.isEmpty) return;
    _pending.add(bytes);
    final now = _clock();
    // The first bytes after a quiet moment go through at once: a session that
    // has just said something must not wait out an interval to say it.
    if (_refreshedAt != null && now - _refreshedAt! < refreshInterval) return;
    _refresh(now, force: false);
  }

  /// Writes text the app generated itself, now, whatever the interval says.
  /// "[process exited with code 1]" is the case that cannot wait: nothing
  /// further is ever going to arrive to carry it. It skips the budget too.
  void write(String text) {
    if (text.isEmpty) return;
    _pending.add(const Utf8Encoder().convert(text));
    _refresh(_clock(), force: true);
  }

  /// Forgets everything queued, for a pane that is no longer cold. For a
  /// **parked** pane the spool replay is what puts the detached output back, so
  /// anything still held here would only be a second copy of it.
  void reset() {
    _pending.reset();
    _decoded.clear();
    _refreshedAt = null;
  }

  /// Draws everything still queued, now, and forgets the interval.
  ///
  /// The other half of [reset]: a pane the park **declined** has no replay to
  /// put the detached output back, so what the interval and the budget were
  /// still holding has to be drawn here or never. One parse per reattach,
  /// bounded by [kColdScreenPendingMaxBytes].
  void flush() {
    _refresh(_clock(), force: true);
    reset();
  }

  void _refresh(Duration now, {required bool force}) {
    final wanted = _pending.length;
    if (wanted <= 0) return;
    // A cold refresh is background work exactly as a warm pane's parse is, so
    // it comes out of the same pool: the budget's total is a pool, not one per
    // tier.
    final allowed = force ? wanted : _budget.take(IngestTier.cold, wanted);
    if (allowed <= 0) return;
    _refreshedAt = now;
    _refreshes++;
    // The decoder is long-lived, so a multi-byte character split across a
    // partial grant survives it.
    _decoderSink.add(_pending.take(allowed));
    if (_decoded.isNotEmpty) {
      final data = _decoded.toString();
      _decoded.clear();
      terminal.write(data);
    }
    _trimToScreen();
  }

  /// Gives the scrollback back again, for the same reason [ScrollbackPark] took
  /// it: a refresh may redraw the screen, never rebuild the buffer parking
  /// released. A pane the park **declined** is skipped entirely — nothing was
  /// released, so this buffer holds the only copy of that pane's history.
  void _trimToScreen() {
    if (!park.isParked || terminal.isUsingAltBuffer) return;
    final lines = terminal.mainBuffer.lines;
    final above = lines.length - terminal.viewHeight;
    if (above > 0) lines.remove(0, above);
  }
}

/// A detached pane's ingest: where its bytes go while nobody can see it, and
/// how it comes back with none of them drawn twice.
///
/// A **parked** pane has its buffer rebuilt on reattach, so what [ColdScreen]
/// drew is erased and the spool replays over the top. A **declined** pane — one
/// a full-screen program owned — had nothing taken and nothing cleared, so what
/// the refresh drew stands, and it is never spooled at all. That is why [spool]
/// is fed behind a condition: a pane doing both would draw every byte twice.
class ColdIngest {
  ColdIngest({
    required this.terminal,
    TerminalIngestBudget? budget,
    IngestClock? clock,
    Duration refreshInterval = kColdScreenRefreshInterval,
  }) : park = ScrollbackPark(terminal) {
    screen = ColdScreen(
      terminal: terminal,
      park: park,
      budget: budget,
      clock: clock,
      refreshInterval: refreshInterval,
    );
  }

  final Terminal terminal;

  /// The scrollback this pane gives up while it is cold — or does not, which is
  /// the whole of the difference above.
  final ScrollbackPark park;

  /// Where a parked pane's output goes instead of into the parser.
  final ScrollbackSpool spool = ScrollbackSpool();

  /// What keeps the pane's *screen* current meanwhile, so a detached session
  /// does not go dark for the status sources.
  late final ColdScreen screen;

  String? get parkedScrollback => park.parked;

  bool get isParked => park.isParked;

  /// Bytes held for a replay. Diagnostics, and what the tests assert on.
  int get spooledBytes => spool.length;

  /// Goes cold, carrying [pending] — whatever the coalescer had queued and
  /// never parsed — into whichever queue this pane turns out to use. Returns
  /// whether scrollback lines were actually released, which decides whether the
  /// command blocks anchored to them are dropped.
  bool detach(Uint8List pending) {
    final released = park.park();
    // The queue goes to the screen as well as the spool: if the process then
    // falls silent forever, an approval prompt sitting in those last bytes
    // would otherwise never be drawn at all.
    add(pending);
    return released;
  }

  /// Queues process output for a pane nobody can see.
  void add(Uint8List bytes) {
    // Only a parked pane replays, because only a parked pane has its buffer
    // cleared first. Spooling one that does not is how a byte is drawn twice.
    if (park.isParked) spool.add(bytes);
    screen.add(bytes);
  }

  /// Queues text the app generated itself. In the spool it belongs among the
  /// process output it arrived with, rather than above history that came before
  /// it; on the screen it skips the interval, because nothing further is ever
  /// going to arrive to carry it.
  void emit(String text) {
    if (park.isParked) spool.add(const Utf8Encoder().convert(text));
    screen.write(text);
  }

  /// Brings the pane back, drawing what it missed exactly once.
  void reattach() {
    if (!park.isParked) {
      // Nothing was taken and nothing is cleared, so the refresh's drawings
      // stand and there is no spool behind them; this is the rest of them.
      screen.flush();
      return;
    }
    // A program may have taken the screen while this pane was cold, and
    // `unpark` writes with `terminal.write`, which goes to whichever buffer is
    // *in front* — left alone the parked snapshot lands on the program's screen
    // and the pane's history is silently gone. `?47` rather than `?1049` for
    // the round trip because it switches buffers and clears neither
    // (parser.dart:985); `?1048` saves and restores the cursor across it, so
    // the program's next write lands where it left off.
    final onAltScreen = terminal.isUsingAltBuffer;
    if (onAltScreen) terminal.write('\x1b[?1048h\x1b[?47l');
    // Before the replay, not after: what the screen refresh drew is about to be
    // written again, in order, from the spool.
    screen.reset();
    park.unpark();
    if (onAltScreen) terminal.write('\x1b[?47h\x1b[?1048l');
    _replay();
  }

  /// Writes what arrived while this pane was parked into its buffer. One write,
  /// bounded by the spool's own cap, so bringing a session back is a single
  /// parse rather than however much the process produced while it was away.
  void _replay() {
    final dropped = spool.droppedBytes;
    final bytes = spool.drain();
    spool.reset();
    if (bytes.isEmpty && dropped == 0) return;
    if (dropped > 0) {
      // Bytes below a kibibyte rather than a rounded-down "0 KiB", which reads
      // as a bug in the notice rather than as a small gap in the output.
      final lost = dropped >= 1024 ? '${dropped ~/ 1024} KiB' : '$dropped bytes';
      terminal.write(
        '\r\n\x1b[90m[… $lost of output while detached was '
        'dropped]\x1b[0m\r\n',
      );
    }
    if (bytes.isNotEmpty) {
      terminal.write(const Utf8Decoder(allowMalformed: true).convert(bytes));
    }
  }
}

/// One process-wide monotonic origin, matching `PtyOutputCoalescer`'s and
/// `TerminalIngestBudget`'s: every pane must read the same clock.
final _elapsed = Stopwatch()..start();

Duration _defaultClock() => _elapsed.elapsed;

/// Adapts a `void Function(String)` to the [Sink] the chunked UTF-8 decoder
/// writes into.
class _CallbackSink implements Sink<String> {
  _CallbackSink(this._write);

  final void Function(String) _write;

  @override
  void add(String data) => _write(data);

  @override
  void close() {}
}
