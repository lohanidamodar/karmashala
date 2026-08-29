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
class PtyOutputCoalescer {
  PtyOutputCoalescer({
    required this.onData,
    FrameCallbackScheduler? scheduleFrameCallback,
    WatchdogScheduler? scheduleWatchdog,
    WatchdogCanceller? cancelWatchdog,
    this.maxFlushBytes = kMaxFlushBytes,
    this.watchdogDelay = const Duration(milliseconds: 16),
  }) : _scheduleFrameCallback =
           scheduleFrameCallback ?? _defaultScheduleFrameCallback,
       _scheduleWatchdog = scheduleWatchdog ?? _defaultScheduleWatchdog,
       _cancelWatchdog = cancelWatchdog ?? _defaultCancelWatchdog {
    _decoderSink = const Utf8Decoder(
      allowMalformed: true,
    ).startChunkedConversion(_CallbackSink(_decoded.write));
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

  /// Queues [bytes] and makes sure a flush is scheduled.
  void add(List<int> bytes) {
    if (_disposed || bytes.isEmpty) return;
    _pending.add(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
    _pendingBytes += bytes.length;
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
