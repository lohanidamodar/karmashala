import 'dart:convert';

import 'package:karmashala/src/features/terminal/data/pty_output_coalescer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/core.dart';

/// Benchmark — NOT part of `flutter test`'s default run. It lives under `tool/`
/// so discovery never picks it up. Run it on demand:
///
///   flutter test tool/benchmark/input_latency_bench.dart
///
/// Answers "where does the time between a key press and the glyph on screen
/// go?" in two parts, because the two stages need different instruments.
///
/// **Part 1 — CPU per keystroke.** Wall clock over many iterations, so the
/// per-call cost of the encode path (keytab lookup, `Terminal.keyInput`) and of
/// writing one echoed character back into the buffer is a number rather than a
/// guess. Machine-dependent; read it for orders of magnitude, not regressions.
///
/// **Part 2 — delivery scheduling.** A discrete-event simulation of the Flutter
/// frame pipeline driving the *real* [PtyOutputCoalescer] through its injected
/// schedulers. Nothing here is re-implemented: the policy under test is the
/// shipping one. The clock is virtual, so the numbers are exact and identical
/// on every machine — which is what makes them worth quoting.
///
/// The model, stated so the numbers can be argued with:
///
/// * vsync every 16 667 us (60 Hz);
/// * a frame runs **only** if something called `scheduleFrame()` since the last
///   one — a desktop Flutter app at an idle shell prompt animates nothing, so
///   this is the case that matters;
/// * `addPostFrameCallback` does **not** schedule a frame (Flutter 3.47.1,
///   `packages/flutter/lib/src/scheduler/binding.dart:833` — the body is one
///   `_postFrameCallbacks.add(callback)`);
/// * `Terminal.write` ends in `notifyListeners()`, which reaches
///   `RenderTerminal._onTerminalChange` → `markNeedsLayout()` → a scheduled
///   frame;
/// * the glyph is reported as visible at the start of the frame that paints it.
///   Raster and present add roughly one more frame, equally to every policy, so
///   they are left out rather than double-counted.
void main() {
  test('per-keystroke CPU cost', () {
    final terminal = Terminal(maxLines: 1000)..resize(120, 40);
    var sunk = 0;
    terminal.onOutput = (data) => sunk += data.length;

    // Warm up: the default keytab is parsed lazily on first use.
    for (var i = 0; i < 1000; i++) {
      terminal.keyInput(TerminalKey.keyA);
    }

    const runs = 200000;
    final encode = Stopwatch()..start();
    for (var i = 0; i < runs; i++) {
      terminal.keyInput(TerminalKey.keyA);
    }
    encode.stop();

    final write = Stopwatch()..start();
    for (var i = 0; i < runs; i++) {
      terminal.write('a');
    }
    write.stop();

    // A key that sits at the far end of the keytab's linear scan, to bound the
    // worst case of `Keytab.find`.
    final worst = Stopwatch()..start();
    for (var i = 0; i < runs; i++) {
      terminal.keyInput(TerminalKey.f12, ctrl: true, shift: true);
    }
    worst.stop();

    void report(String label, Stopwatch sw) {
      // ignore: avoid_print
      print(
        '  $label: ${(sw.elapsedMicroseconds / runs).toStringAsFixed(3)} us '
        '/ call',
      );
    }

    // ignore: avoid_print
    print('per-keystroke CPU ($runs iterations, $sunk bytes emitted)');
    report('Terminal.keyInput(a)      ', encode);
    report('Terminal.write("a")       ', write);
    report('keyInput(Ctrl+Shift+F12)  ', worst);
    expect(encode.elapsedMicroseconds, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('key-press to glyph, by coalescer policy', () {
    // Where in the vsync period the shell's echo lands is arbitrary, so sweep
    // it: a single phase would flatter one policy or the other.
    const phases = 64;
    for (final leadingEdge in [false, true]) {
      final samples = <int>[];
      for (var i = 0; i < phases; i++) {
        final phase = (_Sim.frame * i) ~/ phases;
        samples.add(_Sim(leadingEdge: leadingEdge, echoPhase: phase).run());
      }
      samples.sort();
      final mean = samples.reduce((a, b) => a + b) / samples.length;
      // ignore: avoid_print
      print(
        '${leadingEdge ? 'leading-edge' : 'post-frame only'}: '
        'min=${_ms(samples.first)} '
        'mean=${mean ~/ 1000}.${((mean % 1000) ~/ 100)}ms '
        'p95=${_ms(samples[(samples.length * 95) ~/ 100])} '
        'max=${_ms(samples.last)}',
      );
      expect(samples.first, greaterThanOrEqualTo(0));
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('flushes per second under sustained output, by policy', () {
    for (final leadingEdge in [false, true]) {
      final sim = _Sim(leadingEdge: leadingEdge, echoPhase: 0);
      final flushes = sim.stream(
        // flutter_pty reads 1 KB at a time; a busy shell delivers one such
        // chunk roughly every 200 us.
        chunkInterval: 200,
        chunkBytes: 1024,
        duration: const Duration(seconds: 1).inMicroseconds,
      );
      // ignore: avoid_print
      print(
        '${leadingEdge ? 'leading-edge' : 'post-frame only'}: '
        '$flushes terminal writes for 1 s of 5 MB/s output '
        '(uncoalesced would be 5000)',
      );
      expect(flushes, greaterThan(0));
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

String _ms(int micros) =>
    '${micros ~/ 1000}.${((micros % 1000) ~/ 100)}ms';

/// A discrete-event model of the Flutter frame pipeline, driving the real
/// [PtyOutputCoalescer]. See the file header for the modelling assumptions.
class _Sim {
  _Sim({required this.leadingEdge, required this.echoPhase});

  /// 60 Hz.
  static const frame = 16667;

  /// How long the shell takes to echo a character back. A local ConPTY round
  /// trip; deliberately small, so what is measured is *our* scheduling.
  static const echoLatency = 500;

  final bool leadingEdge;

  /// Offset of the echo's arrival from a vsync boundary.
  final int echoPhase;

  int _now = 0;
  int? _frameDueAt;
  final _postFrame = <VoidCallback>[];
  final _timers = <_FakeTimer>[];

  /// Set by `Terminal.write`; cleared by the frame that paints it.
  bool _dirty = false;
  int? _paintedAt;
  int _flushes = 0;

  PtyOutputCoalescer _newCoalescer() => PtyOutputCoalescer(
    onData: (_) {
      _flushes++;
      // What Terminal.write does at the end: notifyListeners() reaches
      // RenderTerminal._onTerminalChange → markNeedsLayout → scheduleFrame.
      _dirty = true;
      _scheduleFrame();
    },
    scheduleFrameCallback: _postFrame.add,
    scheduleWatchdog: (delay, callback) {
      final timer = _FakeTimer(_now + delay.inMicroseconds, callback);
      _timers.add(timer);
      return timer;
    },
    cancelWatchdog: (handle) => _timers.remove(handle),
    // A threshold no run can reach reproduces the original policy: defer
    // everything to a frame that nothing has scheduled.
    idleThreshold: leadingEdge
        ? kCoalescerIdleThreshold
        : const Duration(days: 365),
    monotonicClock: () => Duration(microseconds: _now),
  );

  void _scheduleFrame() {
    if (_frameDueAt != null) return;
    // The next vsync boundary strictly after now.
    _frameDueAt = ((_now ~/ frame) + 1) * frame;
  }

  /// One key press, its echo [echoLatency] + [echoPhase] later. Returns the
  /// microseconds from the press to the frame that paints the glyph.
  ///
  /// The press happens on a vsync boundary after a second of quiet, which is
  /// what a shell prompt is: the terminal has been idle, nothing is animating,
  /// and no frame is pending when the echo lands.
  int run() {
    _now = 0;
    final coalescer = _newCoalescer();
    final pressedAt = frame * 60;
    _advanceTo(pressedAt);
    _advanceTo(pressedAt + echoLatency + echoPhase);
    coalescer.add(utf8.encode('a'));
    while (_paintedAt == null && _now < pressedAt + 1000000) {
      if (!_step()) break;
    }
    final painted = _paintedAt!;
    _paintedAt = null;
    coalescer.dispose();
    return painted - pressedAt;
  }

  /// Sustained output for [duration], returning how many times the terminal
  /// buffer was written to.
  int stream({
    required int chunkInterval,
    required int chunkBytes,
    required int duration,
  }) {
    _now = 0;
    final coalescer = _newCoalescer();
    _flushes = 0;
    final chunk = Uint8List(chunkBytes);
    var nextChunk = 0;
    while (_now < duration) {
      final due = _nextEvent();
      if (due != null && due < nextChunk) {
        _step();
        continue;
      }
      _advanceTo(nextChunk);
      coalescer.add(chunk);
      nextChunk += chunkInterval;
    }
    coalescer.dispose();
    return _flushes;
  }

  int? _nextEvent() {
    int? due = _frameDueAt;
    for (final timer in _timers) {
      if (due == null || timer.due < due) due = timer.due;
    }
    return due;
  }

  /// Runs the next scheduled event. Returns false when nothing is pending.
  bool _step() {
    final due = _nextEvent();
    if (due == null) return false;
    _advanceTo(due);
    if (_frameDueAt == due) {
      _frameDueAt = null;
      _runFrame();
      return true;
    }
    final timer = _timers.firstWhere((t) => t.due == due);
    _timers.remove(timer);
    timer.callback();
    return true;
  }

  void _runFrame() {
    // Build → layout → paint. The glyph reaches the screen in this frame.
    if (_dirty) {
      _dirty = false;
      _paintedAt ??= _now;
    }
    // Then, and only then, the post-frame callbacks.
    final pending = List<VoidCallback>.of(_postFrame);
    _postFrame.clear();
    for (final callback in pending) {
      callback();
    }
  }

  void _advanceTo(int t) {
    if (t > _now) _now = t;
  }
}

class _FakeTimer {
  _FakeTimer(this.due, this.callback);

  final int due;
  final VoidCallback callback;
}
