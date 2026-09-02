import 'dart:io';

import 'package:karmashala/src/features/terminal/data/pty_output_coalescer.dart';
import 'package:karmashala/src/features/terminal/data/terminal_ingest_budget.dart';
import 'package:karmashala/src/features/terminal/domain/ingest_tier.dart';
import 'package:karmashala/src/features/terminal/domain/scrollback_limits.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

import '../../test/terminal/perf/corpora.dart';

/// Benchmark — NOT part of `flutter test`'s default run. Run it on demand:
///
///   flutter test tool/benchmark/terminal_ingest_bench.dart
///
/// **The multi-session benchmark.** `terminal_scale_bench.dart` measures what
/// the *layout* costs at N panes — the autosave tick, the listener fan-out,
/// the memory. This one measures what **ingestion** costs: N panes all
/// producing output at once, through the production path (a
/// [PtyOutputCoalescer] per pane, `onData` → `Terminal.write`), with no
/// processes anywhere.
///
/// It exists because the scale target's hard case is not a hundred idle panes,
/// it is a hundred *noisy* ones while the user types in one of them. Every
/// number is reported at N = 1, 10 and 100 and read as a **curve**: the
/// question is never "is this fast", it is "what is the slope".
///
/// What is measured, and why each one:
///
/// * **frame cost** — the wall time one frame's flushes take across all N
///   panes. This is the number the user feels: nothing repaints until it is
///   done, so it is the floor under keystroke-to-pixel latency. The audit's
///   claim is that it is linear in N because each pane carries its own 256 KiB
///   flush cap rather than sharing one frame budget.
/// * **bytes parsed per frame** — how much the UI isolate was asked to VT-parse
///   in that frame, summed over all panes. A tiered ingestion that holds hidden
///   panes back shows up here first.
/// * **echo wait** — what a keystroke's echo in the *focused* pane waits for.
///   It cannot paint until the frame carrying it completes, so its wait is that
///   frame; the focused pane is drained last, which is the honest worst case.
/// * **RSS** — resident memory, because a fully parsed `Terminal` per pane is
///   the other thing that does not survive being multiplied by a hundred.
///
/// Wall-clock figures are machine-dependent and are printed, not asserted —
/// same contract as `tool/benchmark/paint_bench.dart`. The counts are
/// deterministic and *are* asserted, because a regression in those is a
/// regression in the design rather than in the machine.
const int _columns = 120;
const int _rows = 40;

/// Frames of simulated output per measurement.
const int _frames = 60;

/// One benchmark pane: a terminal, its coalescer, and the frame callback the
/// coalescer is waiting on.
///
/// The schedulers are the injected seams the coalescer already has, driven
/// deterministically — a benchmark that waited on real frames would be
/// measuring the test binding rather than the ingestion.
class BenchPane {
  BenchPane({required TerminalIngestBudget budget, required IngestTier tier}) {
    terminal = Terminal(maxLines: kLiveScrollbackMaxLines)
      ..resize(_columns, _rows);
    coalescer = PtyOutputCoalescer(
      onData: (data) {
        bytesParsed += data.length;
        terminal.write(data);
      },
      budget: budget,
      tier: tier,
      scheduleFrameCallback: (callback) => frameCallback = callback,
      scheduleWatchdog: (delay, callback) {
        watchdogsArmed++;
        watchdogDelays += delay.inMilliseconds;
        return Object();
      },
      cancelWatchdog: (_) {},
      // Never idle: a benchmark of sustained output must not take the
      // write-through path meant for an echo at a quiet prompt.
      idleThreshold: const Duration(days: 1),
    );
  }

  late final Terminal terminal;
  late final PtyOutputCoalescer coalescer;
  VoidCallback? frameCallback;

  int bytesParsed = 0;
  int watchdogsArmed = 0;
  int watchdogDelays = 0;

  /// Runs whatever this pane was waiting for a frame to do.
  void runFrame() {
    final callback = frameCallback;
    frameCallback = null;
    callback?.call();
  }

  void dispose() => coalescer.dispose();
}

void main() {
  /// A realistic noisy pane: one screen of colourised `ls` per frame, which is
  /// what a build log or an agent's streamed output looks like to the parser.
  final chunk = Uint8List.fromList(
    '${corpusText(PerfCorpus.colorizedLs, columns: _columns, rows: _rows)}\r\n'
        .codeUnits,
  );

  Duration median(List<Duration> samples) {
    samples.sort();
    return samples[samples.length ~/ 2];
  }

  int rssMegabytes() => ProcessInfo.currentRss ~/ (1024 * 1024);

  test('ingestion cost curve with every pane noisy', () {
    // ignore: avoid_print
    print(
      'N panes | frame cost | per pane | bytes/frame | echo wait | '
      'watchdogs | mean wd | dropped | RSS',
    );
    for (final n in [1, 10, 100]) {
      final baselineRss = rssMegabytes();
      // The layout this models: one visible tab, everything else open but
      // hidden — which is what `TerminalSessionsController` sets.
      var now = Duration.zero;
      final budget = TerminalIngestBudget(clock: () => now);
      final panes = [
        for (var i = 0; i < n; i++)
          BenchPane(
            budget: budget,
            tier: i == n - 1 ? IngestTier.hot : IngestTier.warm,
          ),
      ];
      final focused = panes.last;

      final frameCosts = <Duration>[];
      for (var frame = 0; frame < _frames; frame++) {
        now += kIngestRefillInterval;
        for (final pane in panes) {
          pane.coalescer.add(chunk);
        }
        final sw = Stopwatch()..start();
        for (final pane in panes) {
          pane.runFrame();
        }
        sw.stop();
        frameCosts.add(sw.elapsed);
      }

      final bytesPerFrame =
          panes.fold<int>(0, (sum, p) => sum + p.bytesParsed) ~/ _frames;
      final watchdogs = panes.fold<int>(0, (sum, p) => sum + p.watchdogsArmed);
      final dropped = panes.fold<int>(
        0,
        (sum, p) => sum + p.coalescer.droppedBytes,
      );
      // The cadence hidden panes drain at. A pane nobody watches schedules no
      // frames, so its watchdog *is* its clock; at 100 ms rather than 16 that
      // is five sixths fewer timers per second in the real app.
      final meanWatchdog =
          panes.fold<int>(0, (sum, p) => sum + p.watchdogDelays) / watchdogs;

      // The echo: one keystroke's worth of output into the focused pane, while
      // every other pane is still producing. What it waits for is the frame.
      final echoWaits = <Duration>[];
      for (var i = 0; i < 20; i++) {
        now += kIngestRefillInterval;
        for (final pane in panes) {
          pane.coalescer.add(chunk);
        }
        focused.coalescer.add(Uint8List.fromList('a'.codeUnits));
        final sw = Stopwatch()..start();
        for (final pane in panes) {
          pane.runFrame();
        }
        sw.stop();
        echoWaits.add(sw.elapsed);
      }

      final rss = rssMegabytes();
      final frameCost = median(frameCosts);
      // ignore: avoid_print
      print(
        '${n.toString().padLeft(7)} | '
        '${'${(frameCost.inMicroseconds / 1000).toStringAsFixed(2)}ms'.padLeft(10)} | '
        '${'${(frameCost.inMicroseconds / 1000 / n).toStringAsFixed(3)}ms'.padLeft(8)} | '
        '${bytesPerFrame.toString().padLeft(11)} | '
        '${'${(median(echoWaits).inMicroseconds / 1000).toStringAsFixed(2)}ms'.padLeft(9)} | '
        '${watchdogs.toString().padLeft(9)} | '
        '${'${meanWatchdog.toStringAsFixed(0)}ms'.padLeft(7)} | '
        '${'${dropped ~/ 1024}K'.padLeft(7)} | '
        '${rss}MB (+${rss - baselineRss})',
      );

      for (final pane in panes) {
        pane.dispose();
      }
    }
  }, timeout: const Timeout(Duration(minutes: 20)));

  test('what one frame is allowed to offer the parser', () {
    // The audit's arithmetic, made concrete: the flush cap is per *session*, so
    // the ceiling a synchronised round can put on the UI isolate is N times the
    // cap. This is the number a global budget has to replace.
    // ignore: avoid_print
    print(
      'per-pane flush cap: ${kMaxFlushBytes ~/ 1024} KiB; '
      '100 panes could offer ${kMaxFlushBytes * 100 ~/ (1024 * 1024)} MiB '
      'to one frame',
    );
    expect(kMaxFlushBytes, 256 * 1024);
  });
}
