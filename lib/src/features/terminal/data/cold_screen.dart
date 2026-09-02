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
/// It refreshes **whatever buffer the pane is drawing into**, including the
/// alternate one. A full-screen program is the case that matters most — an
/// agent CLI draws its own UI, so the detached panes whose approval prompts
/// nobody can see are exactly the panes a TUI owns — and it is also the case
/// this used to decline, by gating on [ScrollbackPark.isParked] for a park that
/// refuses such a pane outright. [ColdIngest] says what that costs at reattach
/// and how it is paid.
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
  /// tests assert on — a refresh that silently stopped happening would
  /// otherwise look exactly like a pane with nothing to say.
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
  ///
  /// "[process exited with code 1]" is the case, and it is the one message that
  /// cannot wait: nothing further is ever going to arrive to carry it. It skips
  /// the budget too — it is one line, once in a pane's life.
  void write(String text) {
    if (text.isEmpty) return;
    _pending.add(const Utf8Encoder().convert(text));
    _refresh(_clock(), force: true);
  }

  /// Forgets everything queued, for a pane that is no longer cold.
  ///
  /// For a **parked** pane the spool replay is what puts the detached output
  /// back, so anything still held here would only be a second copy of it.
  void reset() {
    _pending.reset();
    _decoded.clear();
    _refreshedAt = null;
  }

  /// Draws everything still queued, now, and forgets the interval.
  ///
  /// The other half of [reset]: for a pane the park **declined** there is no
  /// replay to put the detached output back — the refresh already drew it in
  /// place — so what the interval and the budget were still holding has to be
  /// drawn here or never. One parse per reattach, bounded by
  /// [kColdScreenPendingMaxBytes], which is an eighth of the spool replay it
  /// stands in for.
  void flush() {
    _refresh(_clock(), force: true);
    reset();
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
  ///
  /// A pane the park **declined** is skipped entirely: nothing was released, so
  /// this buffer holds the only copy of that pane's history and trimming it
  /// would destroy what no snapshot can restore. It stays bounded by the
  /// terminal's own `maxLines`, exactly as it was before the pane went cold.
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
/// One invariant, whichever way the pane went cold: **every byte that arrived
/// while it was cold is drawn exactly once, in order, on top of the state it
/// was detached in.** What gets there differs between the two kinds of cold
/// pane, and they are opposites rather than variations:
///
/// * **Parked** — the ordinary pane. Its buffer is rebuilt when it comes back:
///   [ScrollbackPark.unpark] clears it and writes the snapshot in again, so
///   whatever [ColdScreen] drew meanwhile is erased, and the whole spool
///   replays over the top.
/// * **Declined** — a full-screen program owned the display when the pane went
///   cold, and there is no way to write a snapshot back underneath one. Nothing
///   was taken, so nothing is cleared, so what the refresh drew *stands*. Such
///   a pane is therefore never spooled at all, and coming back is a
///   [ColdScreen.flush] of the little the refresh had not reached yet.
///
/// The second case is why [spool] is fed behind a condition rather than
/// unconditionally. A pane that both refreshed its screen and spooled would
/// have every one of those bytes written a second time by the replay, and "a
/// TUI repaints absolutely and would probably recover" is not a guarantee. It
/// makes the reattach cheaper too: at most [kColdScreenPendingMaxBytes] parsed
/// in place, against the [kScrollbackSpoolMaxBytes] a replay can carry.
///
/// Assembled here rather than at each pane because it had been assembled three
/// times over — the PTY pane, the fake pane the controller tests run on, and
/// the throughput gate's model — and only one of them could be the truth.
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
  /// never parsed — into whichever queue this pane turns out to use.
  ///
  /// Returns whether scrollback lines were actually released, which the caller
  /// uses to decide whether to drop the command blocks anchored to them.
  bool detach(Uint8List pending) {
    final released = park.park();
    // The queue goes to the screen as well as the spool, not just the spool: if
    // the process then falls silent forever, an approval prompt sitting in
    // those last bytes would otherwise never be drawn at all.
    add(pending);
    return released;
  }

  /// Queues process output for a pane nobody can see.
  void add(Uint8List bytes) {
    // Only a parked pane replays, because only a parked pane has its buffer
    // cleared first. Spooling one that does not is how a byte comes to be
    // drawn twice.
    if (park.isParked) spool.add(bytes);
    screen.add(bytes);
  }

  /// Queues text the app generated itself.
  ///
  /// "[process exited with code 1]" is the case. In the spool it belongs among
  /// the process output it arrived with, rather than above history that came
  /// before it; on the screen it skips the interval, because nothing further is
  /// ever going to arrive to carry it.
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
    // A program may have taken the screen while this pane was cold — the
    // refresh parses `?1049h` like anything else — and `unpark` writes with
    // `terminal.write`, which goes to whichever buffer is *in front*. Left
    // alone the parked snapshot lands on the program's screen while the main
    // buffer stays empty, so the pane's history is silently gone: the one
    // outcome parking exists to avoid.
    //
    // `?47` rather than `?1049` for the round trip, because it switches buffers
    // and clears neither (parser.dart:985) — the program's frame survives
    // untouched. `?1048` saves and restores the cursor across it, so the
    // program's next write lands where it left off rather than wherever the
    // snapshot finished. The spool then replays on top of the state the process
    // actually believes it is in, which is what keeps anything it goes on to
    // say about buffers — including leaving the alternate one — correct.
    final onAltScreen = terminal.isUsingAltBuffer;
    if (onAltScreen) terminal.write('\x1b[?1048h\x1b[?47l');
    // Before the replay, not after: what the screen refresh drew is about to be
    // written again, in order, from the spool.
    screen.reset();
    park.unpark();
    if (onAltScreen) terminal.write('\x1b[?47h\x1b[?1048l');
    _replay();
  }

  /// Writes what arrived while this pane was parked into its buffer.
  ///
  /// One write, bounded by the spool's own cap, so bringing a session back is a
  /// single parse of at most a few hundred screens rather than however much the
  /// process produced while it was away.
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
