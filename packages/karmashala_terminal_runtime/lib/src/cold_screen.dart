import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:xterm2/xterm.dart';

import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'scrollback_park.dart';
import 'scrollback_spool.dart';
import 'terminal_ingest_budget.dart';

/// How far behind its process a detached pane's screen may fall. One second,
/// the order the status pipeline works at: shorter would buy nothing anybody
/// could act on, longer would let an approval prompt sit unnoticed.
const Duration kColdScreenRefreshInterval = Duration(seconds: 1);

/// Bytes a cold pane holds for its screen before the oldest are dropped — far
/// smaller than the spool, which has to replay rather than redraw.
const int kColdScreenPendingMaxBytes = 32 * 1024;

/// Keeps a detached pane's *screen* current while its scrollback stays parked —
/// a session with no tab is exactly the one whose approval prompt nobody sees.
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

  /// Writes text the app generated itself, now, whatever the interval says:
  /// nothing further is ever going to arrive to carry it.
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

  /// Draws everything still queued, now. A pane the park **declined** has no
  /// replay, so what the budget was holding is drawn here or never.
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

  /// Gives the scrollback back, for the reason [ScrollbackPark] took it. A pane
  /// the park **declined** is skipped: this buffer is its only copy.
  void _trimToScreen() {
    if (!park.isParked || terminal.isUsingAltBuffer) return;
    final lines = terminal.mainBuffer.lines;
    final above = lines.length - terminal.viewHeight;
    if (above > 0) lines.remove(0, above);
  }
}

/// A detached pane's ingest, arranged so nothing is drawn twice: a **parked**
/// pane replays its spool, a **declined** one keeps what the refresh drew.
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

  /// Goes cold, carrying [pending] into whichever queue this pane uses. Returns
  /// whether lines were released, which decides if command blocks are dropped.
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

  /// Queues text the app generated itself. On the screen it skips the interval,
  /// because nothing further is ever going to arrive to carry it.
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
    // `unpark` writes to whichever buffer is *in front*, so a TUI would swallow
    // the snapshot: `?47` switches without clearing (parser.dart:985).
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
      final lost = dropped >= 1024
          ? '${dropped ~/ 1024} KiB'
          : '$dropped bytes';
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
