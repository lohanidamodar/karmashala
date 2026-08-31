import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../domain/ingest_tier.dart';
import 'scrollback_park.dart';
import 'scrollback_spool.dart';
import 'terminal_ingest_budget.dart';

/// How far behind its process a detached pane's screen may fall.
///
/// One second, because that is the order the status pipeline works at: the
/// registry recomposes a session from the sources it holds, and a grid read a
/// second late is a grid read in the same cycle. Shorter would buy nothing
/// anybody could act on; longer would let an approval prompt sit unnoticed.
const Duration kColdScreenRefreshInterval = Duration(seconds: 1);

/// Bytes a cold pane holds for its screen before the oldest are dropped.
///
/// A screen is 40-odd rows, so this is several screens' worth even for output
/// dense with escape sequences, and dropping the front is exactly right for
/// something only the *end* of which is ever displayed. It is deliberately far
/// smaller than [kScrollbackSpoolMaxBytes]: the spool has to be able to replay
/// what the user missed, and this only has to be able to draw the last screen
/// of it.
const int kColdScreenPendingMaxBytes = 32 * 1024;

/// Keeps a detached pane's *screen* current while its scrollback stays parked.
///
/// Visibility-aware ingestion stopped parsing a cold pane at all and spooled its
/// bytes instead. That is right for the scrollback and wrong for the screen:
/// `terminalTailLines` reads the bottom of the grid to tell whether an agent is
/// waiting for approval, and a session with no tab is precisely the session
/// nobody is watching for. Left alone, a detached pane's status froze at the
/// moment it was detached — behaviour that only works while a pane is visible,
/// which at a hundred sessions is behaviour that mostly does not work.
///
/// The cost is kept to the screen, three ways:
///
/// * **at most one parse per [kColdScreenRefreshInterval]**, so a noisy pane
///   costs the same as a quiet one and an idle pane costs nothing at all;
/// * **out of the shared background pool**, the same one warm panes draw on, so
///   a hundred cold panes cost one pool rather than a hundred allowances;
/// * **trimmed straight back to the viewport**, so the memory floor is the one
///   [ScrollbackPark] already established.
///
/// There is no timer. A refresh is driven by bytes arriving, which is the only
/// moment at which the screen could have become stale.
///
/// What is written here is thrown away when the pane comes back:
/// [ScrollbackPark.unpark] clears the buffer before replaying the parked window
/// and the spool, so the screen refresh can never show up twice.
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

  /// The pane's parked scrollback. Also the switch: a pane that is not parked
  /// is one [ScrollbackPark] declined to touch — a full-screen program owns the
  /// display — and this leaves it exactly as it found it.
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
  /// tests assert on — a refresh that silently stopped happening would
  /// otherwise look exactly like a pane with nothing to say.
  int get refreshes => _refreshes;

  /// Bytes held for the screen but not yet parsed.
  @visibleForTesting
  int get pendingBytes => _pending.length;

  /// Queues process output and redraws the screen if an interval has passed.
  void add(Uint8List bytes) {
    if (!park.isParked || bytes.isEmpty) return;
    _pending.add(bytes);
    final now = _clock();
    // The first bytes after a quiet moment go through at once: a session that
    // has just said something must not wait out an interval to say it.
    if (_refreshedAt != null && now - _refreshedAt! < refreshInterval) return;
    _refresh(now, force: false);
  }

  /// Writes text the app generated itself, now, whatever the interval says.
  ///
  /// "[process exited with code 1]" is the case, and it is the one message that
  /// cannot wait: nothing further is ever going to arrive to carry it. It skips
  /// the budget too — it is one line, once in a pane's life.
  void write(String text) {
    if (!park.isParked || text.isEmpty) return;
    _pending.add(const Utf8Encoder().convert(text));
    _refresh(_clock(), force: true);
  }

  /// Forgets everything queued, for a pane that is no longer cold.
  ///
  /// The spool replay is what puts the detached output back, so anything still
  /// held here would only be a second copy of it.
  void reset() {
    _pending.reset();
    _decoded.clear();
    _refreshedAt = null;
  }

  void _refresh(Duration now, {required bool force}) {
    final wanted = _pending.length;
    if (wanted <= 0) return;
    // A cold refresh is background work exactly as a warm pane's parse is, so
    // it comes out of the same pool: the point of one global budget is that the
    // background's total cost is a pool, not a pool per tier.
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
  /// it in the first place. A refresh is allowed to redraw the screen; it is not
  /// allowed to rebuild the buffer the pane was parked to release.
  void _trimToScreen() {
    if (terminal.isUsingAltBuffer) return;
    final lines = terminal.mainBuffer.lines;
    final above = lines.length - terminal.viewHeight;
    if (above > 0) lines.remove(0, above);
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
