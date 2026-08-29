import 'dart:convert';

import 'package:chitragupta/src/features/terminal/data/pty_output_coalescer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Drives the coalescer with no real frames and no real clock, so the flush
/// policy can be tested exactly instead of by waiting.
class _Harness {
  _Harness({int maxFlushBytes = kMaxFlushBytes}) {
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
    );
  }

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
}
