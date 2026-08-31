import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

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
    this.maxFlushBytes = kMaxFlushBytes,
    this.watchdogDelay = const Duration(milliseconds: 16),
    this.idleThreshold = kCoalescerIdleThreshold,
  }) : _scheduleFrameCallback =
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

  /// How long to wait for a frame before draining on a timer instead.
  final Duration watchdogDelay;

  /// How quiet the coalescer must have been for the next bytes to be written
  /// through immediately. See the class doc; a benchmark reproduces the
  /// original defer-everything policy by setting this beyond any run's length.
  final Duration idleThreshold;

  final MonotonicClock _clock;
  late Duration _lastFlushAt;

  final _pending = <Uint8List>[];
  final _decoded = StringBuffer();
  late final ByteConversionSink _decoderSink;

  int _pendingBytes = 0;
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

  void _schedule() {
    if (_scheduled || _disposed) return;
    _scheduled = true;
    // A visible terminal already schedules frames, so the post-frame callback
    // lands this output in the frame it would have appeared in anyway. A hidden
    // terminal produces no frames at all, so the watchdog drains it instead.
    // Whichever fires first cancels the other.
    _scheduleFrameCallback(flush);
    _watchdogHandle = _scheduleWatchdog(watchdogDelay, flush);
  }

  /// Decodes and writes up to [maxFlushBytes]; reschedules if data remains.
  @visibleForTesting
  void flush() {
    if (_disposed || !_scheduled) return;
    _scheduled = false;
    _lastFlushAt = _clock();
    final handle = _watchdogHandle;
    _watchdogHandle = null;
    if (handle != null) _cancelWatchdog(handle);

    var budget = maxFlushBytes;
    while (budget > 0 && _pending.isNotEmpty) {
      final chunk = _pending.first;
      if (chunk.length <= budget) {
        _pending.removeAt(0);
        _pendingBytes -= chunk.length;
        budget -= chunk.length;
        _decoderSink.add(chunk);
      } else {
        _pending[0] = Uint8List.sublistView(chunk, budget);
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
