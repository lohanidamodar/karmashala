import 'dart:convert';

import 'package:chitragupta/src/features/terminal/data/pty_output_coalescer.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Drives the coalescer with no real frames and no real clock, so the flush
/// policy can be tested exactly instead of by waiting.
class _Harness {
  _Harness({
    int maxFlushBytes = kMaxFlushBytes,
    Duration idleThreshold = kCoalescerIdleThreshold,
  }) {
    coalescer = PtyOutputCoalescer(
      onData: writes.add,
      scheduleFrameCallback: frameCallbacks.add,
      scheduleWatchdog: (delay, callback) {
        final handle = Object();
        watchdogs[handle] = callback;
        return handle;
      },
      cancelWatchdog: watchdogs.remove,
      maxFlushBytes: maxFlushBytes,
      idleThreshold: idleThreshold,
      monotonicClock: () => now,
    );
  }

  /// The coalescer's clock, advanced by the test rather than by waiting.
  Duration now = Duration.zero;

  late final PtyOutputCoalescer coalescer;
  final writes = <String>[];
  final frameCallbacks = <VoidCallback>[];
  final watchdogs = <Object, VoidCallback>{};

  /// Runs the pending post-frame callbacks, as a real frame would.
  void pumpFrame() {
    final pending = List<VoidCallback>.of(frameCallbacks);
    frameCallbacks.clear();
    for (final callback in pending) {
      callback();
    }
  }

  /// Fires the pending watchdog timers, which is what a hidden terminal (no
  /// frames at all) relies on.
  void fireWatchdogs() {
    final pending = List<VoidCallback>.of(watchdogs.values);
    watchdogs.clear();
    for (final callback in pending) {
      callback();
    }
  }
}

void main() {
  test('coalesces many chunks into a single write per frame', () {
    final harness = _Harness();
    for (var i = 0; i < 100; i++) {
      harness.coalescer.add(utf8.encode('chunk$i '));
    }
    expect(
      harness.writes,
      isEmpty,
      reason: 'nothing is written before a frame',
    );

    harness.pumpFrame();
    expect(harness.writes.length, 1);
    expect(harness.writes.single, startsWith('chunk0 chunk1 '));
    expect(harness.writes.single, endsWith('chunk99 '));
  });

  test('a multi-byte sequence split across flushes still decodes', () {
    final harness = _Harness();
    final bytes = utf8.encode('नमस्ते');
    harness.coalescer.add(bytes.sublist(0, 3));
    harness.pumpFrame();
    harness.coalescer.add(bytes.sublist(3));
    harness.pumpFrame();
    expect(harness.writes.join(), 'नमस्ते');
  });

  test('caps a huge burst per flush and carries the remainder', () {
    final harness = _Harness(maxFlushBytes: 16);
    harness.coalescer.add(utf8.encode('0123456789abcdefGHIJ'));

    harness.pumpFrame();
    expect(harness.writes.single, '0123456789abcdef');
    expect(harness.coalescer.pendingBytes, 4);

    harness.pumpFrame();
    expect(harness.writes.join(), '0123456789abcdefGHIJ');
    expect(harness.coalescer.pendingBytes, 0);
  });

  test('output order is preserved across capped flushes', () {
    final harness = _Harness(maxFlushBytes: 4);
    for (var i = 0; i < 10; i++) {
      harness.coalescer.add(utf8.encode('$i'));
    }
    for (var i = 0; i < 10; i++) {
      harness.pumpFrame();
    }
    expect(harness.writes.join(), '0123456789');
  });

  test('a hidden terminal (no frames) still drains via the watchdog', () {
    final harness = _Harness();
    harness.coalescer.add(utf8.encode('hidden'));
    harness.fireWatchdogs();
    expect(harness.writes.single, 'hidden');
  });

  test('the frame flush cancels the watchdog so output is written once', () {
    final harness = _Harness();
    harness.coalescer.add(utf8.encode('once'));
    harness.pumpFrame();
    harness.fireWatchdogs();
    expect(harness.writes, ['once']);
  });

  test('dispose drops pending data and stops flushing', () {
    final harness = _Harness();
    harness.coalescer.add(utf8.encode('gone'));
    harness.coalescer.dispose();
    harness.pumpFrame();
    harness.fireWatchdogs();
    expect(harness.writes, isEmpty);
  });

  test('malformed bytes are replaced, never thrown', () {
    final harness = _Harness();
    harness.coalescer.add([0xC3, 0x28]);
    harness.pumpFrame();
    expect(harness.writes.single, isNotEmpty);
  });

  test('an empty chunk schedules nothing', () {
    final harness = _Harness();
    harness.coalescer.add(const <int>[]);
    expect(harness.frameCallbacks, isEmpty);
    expect(harness.watchdogs, isEmpty);
  });

  testWidgets('the default schedulers drain without an explicit frame', (
    tester,
  ) async {
    final writes = <String>[];
    final coalescer = PtyOutputCoalescer(onData: writes.add)
      ..add(utf8.encode('real'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(writes.single, 'real');
    coalescer.dispose();
  });

  // --- the interactive path ---------------------------------------------------

  test('bytes after a quiet frame are written through at once', () {
    // What an echoed keystroke looks like: the pane has been idle, so no frame
    // is pending to carry the output and the watchdog is the only thing that
    // would ever run the flush.
    final harness = _Harness()..now = const Duration(seconds: 4);
    harness.coalescer.add(utf8.encode('a'));

    expect(
      harness.writes,
      ['a'],
      reason: 'the echo must not wait for a frame that nobody scheduled',
    );
    expect(harness.watchdogs, isEmpty, reason: 'no timer left armed');
  });

  test('a second chunk inside the same frame is still batched', () {
    final harness = _Harness()..now = const Duration(seconds: 4);
    harness.coalescer.add(utf8.encode('a'));
    expect(harness.writes, ['a']);

    // 1 ms later: still the same frame, so this defers as it always did.
    harness.now += const Duration(milliseconds: 1);
    harness.coalescer.add(utf8.encode('b'));
    expect(harness.writes, ['a']);

    harness.pumpFrame();
    expect(harness.writes, ['a', 'b']);
  });

  test('sustained output never takes the immediate path', () {
    final harness = _Harness()..now = const Duration(seconds: 4);
    // The first chunk of a burst is indistinguishable from an echo and goes
    // straight through; everything arriving behind it coalesces per frame.
    for (var i = 0; i < 100; i++) {
      harness.coalescer.add(utf8.encode('chunk$i '));
      harness.now += const Duration(microseconds: 200);
    }
    expect(harness.writes.length, 1, reason: 'one leading write');
    harness.pumpFrame();
    expect(harness.writes.length, 2, reason: 'the other 99 chunks, batched');
    expect(harness.writes.join(), startsWith('chunk0 chunk1 '));
    expect(harness.writes.join(), endsWith('chunk99 '));
  });

  test('a pane whose first output arrives at once is not rushed', () {
    // The clock starts when the coalescer is built, so the shell banner — which
    // is not an echo of anything — takes the ordinary batched path.
    final harness = _Harness();
    harness.coalescer.add(utf8.encode('banner'));
    expect(harness.writes, isEmpty);
    harness.pumpFrame();
    expect(harness.writes, ['banner']);
  });

  testWidgets(
    'a post-frame callback alone schedules no frame, which is why the '
    'immediate path exists',
    (tester) async {
      // The premise of the whole leading-edge flush, pinned against the SDK: on
      // a settled tree `addPostFrameCallback` adds a callback and nothing else,
      // so a terminal that only ever registers one waits for its watchdog.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);

      var ran = false;
      tester.binding.addPostFrameCallback((_) => ran = true);
      expect(
        tester.binding.hasScheduledFrame,
        isFalse,
        reason: 'addPostFrameCallback does not request a frame',
      );
      expect(ran, isFalse);
    },
  );
}
