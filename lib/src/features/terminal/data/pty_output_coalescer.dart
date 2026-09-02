import 'dart:collection';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../domain/ingest_tier.dart';
import 'terminal_ingest_budget.dart';

/// Most bytes decoded and handed to the terminal in a single flush. Anything
/// beyond this is carried to the next flush, so `cat hugefile` cannot stall a
/// frame.
const kMaxFlushBytes = 256 * 1024;

typedef FrameCallbackScheduler = void Function(VoidCallback callback);
typedef WatchdogScheduler =
    Object Function(Duration delay, VoidCallback callback);
typedef WatchdogCanceller = void Function(Object handle);

/// A monotonically increasing time source. Injected so the idle test below can
/// be driven exactly rather than by waiting.
typedef MonotonicClock = Duration Function();

/// How long the coalescer must have been quiet before the next bytes are
/// treated as interactive and flushed straight through.
///
/// One frame. Below this, output is arriving faster than the screen refreshes
/// and there is nothing to gain by writing twice into the same frame; above it,
/// the terminal was idle, which at a shell prompt means the bytes are an echo
/// of something the user just typed.
const kCoalescerIdleThreshold = Duration(milliseconds: 16);

/// How long a **hidden** pane waits before draining on a timer.
///
/// A hidden pane schedules no frames, so the watchdog is its only clock. At the
/// hot cadence that is one timer per pane per frame — 100 panes armed 6 000
/// timers over 60 frames in `terminal_ingest_bench.dart`. Nobody is watching
/// these draw, so a sixth of the rate costs nothing anyone can see and removes
/// five sixths of the timers.
const kHiddenCoalescerWatchdog = Duration(milliseconds: 100);

/// Most bytes a pane may hold undecoded before the oldest are dropped.
///
/// A warm pane draws from a shared pool, so a pane producing faster than the
/// pool refills would otherwise queue without bound: a hundred of them is how
/// you turn a throttle into a memory leak. Dropping the oldest is the same
/// contract the live scrollback already has — output old enough falls off the
/// top — applied before the parse rather than after it.
///
/// **The known cost:** dropped bytes can cut an escape sequence, and a
/// full-screen program in a hidden tab can be left drawing against a state the
/// parser no longer agrees with until its next full repaint. It takes sustained
/// overload of a pane nobody is looking at to reach, and the alternative is
/// unbounded memory.
const kMaxPendingBytes = 512 * 1024;

/// Buffers raw PTY bytes and hands them to the terminal at most once per frame.
///
/// `flutter_pty` reads 1 KB at a time, so a busy shell produced hundreds of
/// stream events a second, each one its own UTF-8 decode, `Terminal.write` and
/// `notifyListeners()`. Flutter coalesced the resulting *repaints*, but the
/// parsing and allocation still landed on the UI isolate and showed up as jank.
///
/// Bytes — not strings — are buffered, so a multi-byte character split across
/// two PTY reads survives; one long-lived streaming decoder carries partial
/// sequences across flush boundaries.
///
/// ## Why the first bytes after a quiet moment skip the queue
///
/// Deferring *everything* to a frame is what a coalescer is for under load, but
/// it is the wrong answer for an echo. `addPostFrameCallback` does not schedule
/// a frame — Flutter 3.47.1's implementation is a single
/// `_postFrameCallbacks.add(callback)` — and a desktop terminal sitting at a
/// prompt animates nothing, so no frame is pending when a keystroke's echo
/// arrives. Nothing then runs the flush until the 16 ms watchdog timer fires,
/// and only *then* does `Terminal.write` mark the render object dirty and ask
/// for a frame. Every echoed character paid a timer plus a frame it had missed.
///
/// So bytes arriving after [idleThreshold] of quiet are written through
/// immediately: they mark the terminal dirty before any frame starts, and the
/// very next one paints them. Under sustained output the threshold is never met
/// — chunks arrive microseconds apart — and the per-frame batching Loop 26
/// added is exactly as it was.
class PtyOutputCoalescer {
  PtyOutputCoalescer({
    required this.onData,
    FrameCallbackScheduler? scheduleFrameCallback,
    WatchdogScheduler? scheduleWatchdog,
    WatchdogCanceller? cancelWatchdog,
    MonotonicClock? monotonicClock,
    TerminalIngestBudget? budget,
    IngestTier tier = IngestTier.hot,
    this.maxFlushBytes = kMaxFlushBytes,
    this.maxPendingBytes = kMaxPendingBytes,
    this.watchdogDelay = const Duration(milliseconds: 16),
    this.hiddenWatchdogDelay = kHiddenCoalescerWatchdog,
    this.idleThreshold = kCoalescerIdleThreshold,
  }) : _budget = budget ?? terminalIngestBudget,
       // The field is private and has a setter that does work, so there is no
       // initialising formal to use here.
       // ignore: prefer_initializing_formals
       _tier = tier,
       _scheduleFrameCallback =
           scheduleFrameCallback ?? _defaultScheduleFrameCallback,
       _scheduleWatchdog = scheduleWatchdog ?? _defaultScheduleWatchdog,
       _cancelWatchdog = cancelWatchdog ?? _defaultCancelWatchdog,
       _clock = monotonicClock ?? _defaultClock {
    _decoderSink = const Utf8Decoder(
      allowMalformed: true,
    ).startChunkedConversion(_CallbackSink(_decoded.write));
    // The clock starts here: a pane's first output is a shell banner, not an
    // echo of anything, so there is nothing to be gained by rushing it.
    _lastFlushAt = _clock();
  }

  /// Receives each flush's decoded text — in production, `Terminal.write`.
  final void Function(String data) onData;
  final FrameCallbackScheduler _scheduleFrameCallback;
  final WatchdogScheduler _scheduleWatchdog;
  final WatchdogCanceller _cancelWatchdog;

  /// Upper bound on bytes decoded in one flush.
  final int maxFlushBytes;

  /// Upper bound on bytes queued but not yet decoded; see [kMaxPendingBytes].
  final int maxPendingBytes;

  /// How long a *visible* pane waits for a frame before draining on a timer.
  final Duration watchdogDelay;

  /// How long a hidden pane waits instead; see [kHiddenCoalescerWatchdog].
  final Duration hiddenWatchdogDelay;

  /// The frame budget every pane shares. See [TerminalIngestBudget].
  final TerminalIngestBudget _budget;

  IngestTier _tier;

  /// How visible this pane is, which decides its share of the frame and how
  /// often it drains. Set by the sessions controller, never by the pane.
  IngestTier get tier => _tier;
  set tier(IngestTier value) {
    if (_tier == value) return;
    _tier = value;
    // A pane that just became visible must not wait out a hidden pane's
    // watchdog; re-arming is what makes activation feel immediate.
    if (_scheduled && value == IngestTier.hot) {
      _scheduled = false;
      _cancelPending();
      _schedule();
    }
  }

  /// Bytes dropped because [maxPendingBytes] was reached.
  int get droppedBytes => _droppedBytes;

  /// How quiet the coalescer must have been for the next bytes to be written
  /// through immediately. See the class doc; a benchmark reproduces the
  /// original defer-everything policy by setting this beyond any run's length.
  final Duration idleThreshold;

  final MonotonicClock _clock;
  late Duration _lastFlushAt;

  /// Queued PTY chunks, oldest first.
  ///
  /// A [ListQueue], not a [List]. Both [flush] and [_trimPending] consume from
  /// the head, and `removeAt(0)` on a list shifts every remaining element — so
  /// draining a queue of n chunks cost O(n²). Under a flood that is thousands
  /// of small reads, and it showed: `PtyOutputCoalescer` was **32% of the app's
  /// CPU** while 20,000 lines streamed into a pane, a third of it in the trim
  /// alone. `removeFirst` is O(1).
  final _pending = ListQueue<Uint8List>();
  final _decoded = StringBuffer();
  late final ByteConversionSink _decoderSink;

  int _pendingBytes = 0;
  int _droppedBytes = 0;
  bool _scheduled = false;
  bool _disposed = false;
  Object? _watchdogHandle;

  /// Bytes queued but not yet decoded.
  @visibleForTesting
  int get pendingBytes => _pendingBytes;

  /// Queues [bytes] and makes sure a flush is scheduled — or, when these are
  /// the first bytes after a quiet frame, writes them through at once.
  void add(List<int> bytes) {
    if (_disposed || bytes.isEmpty) return;
    _pending.add(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
    _pendingBytes += bytes.length;
    _trimPending();
    if (!_scheduled && _clock() - _lastFlushAt >= idleThreshold) {
      // The interactive case: an echo, with no frame pending to carry it.
      // Writing now marks the terminal dirty before the frame this write is
      // about to ask for, so it is painted in that frame rather than the next.
      _scheduled = true;
      flush();
      return;
    }
    _schedule();
  }

  /// Drops the oldest queued bytes once the queue is over its bound.
  ///
  /// Only ever reached by a pane drawing on the shared warm pool while its
  /// producer outruns it; a hot pane's reserve is larger than the queue bound,
  /// so it drains faster than it can fill.
  void _trimPending() {
    while (_pendingBytes > maxPendingBytes && _pending.isNotEmpty) {
      final first = _pending.first;
      final excess = _pendingBytes - maxPendingBytes;
      if (first.length <= excess) {
        _pending.removeFirst();
        _pendingBytes -= first.length;
        _droppedBytes += first.length;
      } else {
        // A queue has no index assignment: replacing the head is a remove and
        // an add, both O(1).
        _pending.removeFirst();
        _pending.addFirst(Uint8List.sublistView(first, excess));
        _pendingBytes -= excess;
        _droppedBytes += excess;
      }
    }
  }

  void _cancelPending() {
    final handle = _watchdogHandle;
    _watchdogHandle = null;
    if (handle != null) _cancelWatchdog(handle);
  }

  void _schedule() {
    if (_scheduled || _disposed) return;
    _scheduled = true;
    // A visible terminal already schedules frames, so the post-frame callback
    // lands this output in the frame it would have appeared in anyway. A hidden
    // terminal produces no frames at all, so the watchdog drains it instead.
    // Whichever fires first cancels the other.
    _scheduleFrameCallback(flush);
    _watchdogHandle = _scheduleWatchdog(
      _tier == IngestTier.hot ? watchdogDelay : hiddenWatchdogDelay,
      flush,
    );
  }

  /// Decodes and writes up to [maxFlushBytes]; reschedules if data remains.
  @visibleForTesting
  void flush() {
    if (_disposed || !_scheduled) return;
    _scheduled = false;
    _lastFlushAt = _clock();
    _cancelPending();

    // What this pane may parse *now*, out of one budget shared by every pane in
    // the app. The active pane draws on a reserve nothing else can take; hidden
    // panes share a pool, so a hundred of them cost what a pool costs rather
    // than a hundred times what one pane costs.
    final wanted = _pendingBytes < maxFlushBytes ? _pendingBytes : maxFlushBytes;
    var budget = _budget.take(_tier, wanted);
    if (budget <= 0) {
      // Nothing this interval. The bytes stay queued (bounded by
      // [maxPendingBytes]) and we come back.
      if (_pending.isNotEmpty) _schedule();
      return;
    }
    while (budget > 0 && _pending.isNotEmpty) {
      final chunk = _pending.first;
      if (chunk.length <= budget) {
        _pending.removeFirst();
        _pendingBytes -= chunk.length;
        budget -= chunk.length;
        _decoderSink.add(chunk);
      } else {
        _pending.removeFirst();
        _pending.addFirst(Uint8List.sublistView(chunk, budget));
        _pendingBytes -= budget;
        _decoderSink.add(Uint8List.sublistView(chunk, 0, budget));
        budget = 0;
      }
    }

    if (_decoded.isNotEmpty) {
      final data = _decoded.toString();
      _decoded.clear();
      onData(data);
    }

    if (_pending.isNotEmpty) _schedule();
  }

  /// Hands back everything queued but not yet decoded, leaving the queue empty.
  ///
  /// Used when a pane goes cold: its bytes move to a spool instead of being
  /// parsed on the way out, so going cold costs no flush. A multi-byte
  /// character split across this boundary can be mangled — the streaming
  /// decoder's partial state stays here while its tail leaves — which the
  /// spool's replay tolerates with `allowMalformed`.
  Uint8List takePending() {
    if (_pending.isEmpty) return Uint8List(0);
    final out = Uint8List(_pendingBytes);
    var at = 0;
    for (final chunk in _pending) {
      out.setRange(at, at + chunk.length, chunk);
      at += chunk.length;
    }
    _pending.clear();
    _pendingBytes = 0;
    _scheduled = false;
    _cancelPending();
    return out;
  }

  /// Drops anything still buffered and stops scheduling.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final handle = _watchdogHandle;
    _watchdogHandle = null;
    if (handle != null) _cancelWatchdog(handle);
    _pending.clear();
    _pendingBytes = 0;
    _decoded.clear();
    _decoderSink.close();
  }
}

void _defaultScheduleFrameCallback(VoidCallback callback) {
  SchedulerBinding.instance.addPostFrameCallback((_) => callback());
}

Object _defaultScheduleWatchdog(Duration delay, VoidCallback callback) =>
    Timer(delay, callback);

/// One process-wide monotonic origin, so every coalescer reads the same clock
/// and none of them depends on the wall clock (which can step backwards).
final _elapsed = Stopwatch()..start();

Duration _defaultClock() => _elapsed.elapsed;

void _defaultCancelWatchdog(Object handle) => (handle as Timer).cancel();

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
