import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/data/pty_output_coalescer.dart';
import 'package:karmashala/src/features/terminal/data/terminal_ingest_budget.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';

/// What draining the pending queue costs when a producer floods a pane.
///
/// Both [PtyOutputCoalescer.flush] and its trim consume from the *head* of the
/// queue. While that queue was a `List`, `removeAt(0)` shifted every remaining
/// element, so draining n chunks cost O(n²) — and a flood is thousands of small
/// PTY reads. Profiled against a real 20,000-line flood, the coalescer was 32%
/// of the app's entire CPU, a third of that in the trim alone.
///
/// The bound here is deliberately loose: it is not measuring how fast the
/// machine is, it is separating linear from quadratic, and those are two orders
/// of magnitude apart at this size.
void main() {
  PtyOutputCoalescer build({
    required void Function(String) onData,
    required int maxPendingBytes,
  }) {
    final coalescer = PtyOutputCoalescer(
      onData: onData,
      budget: TerminalIngestBudget(),
      tier: IngestTier.hot,
      // Flushes are driven explicitly here, so the frame callback is dropped.
      scheduleFrameCallback: (_) {},
      scheduleWatchdog: (_, _) => Object(),
      cancelWatchdog: (_) {},
      maxPendingBytes: maxPendingBytes,
      // Never idle, so writes go through the queue rather than the
      // write-through path meant for an echo at a quiet prompt.
      monotonicClock: () => Duration.zero,
      idleThreshold: const Duration(days: 1),
    );
    return coalescer;
  }

  test('a flood of small chunks is all delivered', () {
    var written = 0;
    final coalescer = build(
      onData: (data) => written += data.length,
      maxPendingBytes: 64 * 1024 * 1024,
    );

    final chunk = Uint8List.fromList(List.filled(64, 0x61));
    final watch = Stopwatch()..start();
    for (var i = 0; i < 40000; i++) {
      coalescer.add(chunk);
    }
    // Drain whatever the budget allows, repeatedly, until the queue empties.
    for (var i = 0; i < 4000; i++) {
      coalescer.flush();
    }
    watch.stop();

    // Correctness only. A timing bound here did *not* separate the two
    // implementations reliably — the flush budget means each pass takes only a
    // little off the head, so the queue never grows long enough for the shift
    // to dominate. The trim below is where the quadratic cost actually showed,
    // and that is where the cost is guarded.
    expect(written, 40000 * 64, reason: 'every byte queued is written');
    expect(watch.elapsedMilliseconds, isNotNull);
  });

  test('trimming an over-full queue is linear too', () {
    // The trim runs on every `add` once the queue is over its bound, which is
    // exactly the state a flooded background pane lives in.
    var written = 0;
    final coalescer = build(
      onData: (data) => written += data.length,
      maxPendingBytes: 16 * 1024,
    );

    final chunk = Uint8List.fromList(List.filled(32, 0x62));
    final watch = Stopwatch()..start();
    for (var i = 0; i < 200000; i++) {
      coalescer.add(chunk);
    }
    watch.stop();

    // Measured on an M1: 12 ms with a queue against 1.2 s with a list.
    expect(watch.elapsedMilliseconds, lessThan(400));
    expect(coalescer.droppedBytes, greaterThan(0), reason: 'it did trim');
  });
}
