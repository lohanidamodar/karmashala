import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala/src/features/terminal/data/cold_screen.dart';
import 'package:karmashala/src/features/terminal/data/pty_output_coalescer.dart';
import 'package:karmashala/src/features/terminal/data/scrollback_park.dart';
import 'package:karmashala/src/features/terminal/data/scrollback_spool.dart';
import 'package:karmashala/src/features/terminal/data/terminal_ingest_budget.dart';
import 'package:karmashala/src/features/terminal/domain/ingest_tier.dart';
import 'package:karmashala/src/features/terminal/domain/scrollback_limits.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

import '../../terminal/perf/corpora.dart';

/// What **sustained ingest** costs — bytes arriving from a PTY, parsed by xterm
/// on the UI isolate — as a gate rather than as a benchmark.
///
/// Every other terminal perf guard in this repo measures *painting*:
/// `test/terminal/perf/draw_ops_test.dart` counts canvas calls,
/// `pixel_equivalence_test.dart` proves the batched painter draws the same
/// pixels, `scale_curve_test.dart` counts the bytes the shared budget hands
/// out. None of them measures the thing an agent CLI actually does to this app,
/// which is print thousands of lines into a pane the user is watching. That is
/// the hot path of the product and it had no gate at all.
///
/// **Counted, not timed** — the house rule (`attention_inbox_cost_test.dart`
/// says why: a stopwatch assertion over microseconds fails when the machine is
/// busy, and three agents re-ran it rather than read it). The units here are
/// the four things the UI isolate really spends on a byte of output:
///
/// * **parse entries** — `Terminal.write` calls. One entry is one trip through
///   `EscapeParser`, and the coalescer exists to make this a per-*frame* count
///   rather than a per-PTY-read one.
/// * **code points parsed** — what the parser consumed, exactly.
/// * **lines allocated** — fresh `BufferLine`s pushed into the buffer. Each one
///   is a `Uint32List(_calcCapacity(width) * 4)`; at 200 columns that is a
///   4 KiB allocation *per line of output*, which is the memory traffic behind
///   a long build log.
/// * **notifications** — `notifyListeners()` after each write, and who it
///   reaches.
///
/// Wall-clock figures are printed beside the assertions for the record and are
/// deliberately **not** asserted — the same contract `scale_curve_test.dart`
/// and `tool/benchmark/paint_bench.dart` keep.
void main() {
  group('one pane, sustained output', () {
    for (final corpus in PerfCorpus.values) {
      test('${corpus.name}: cost is linear in the bytes ingested', () {
        // Doubling repeats must double every counted unit. Exactly, not
        // approximately: each repeat is the same screen written from the same
        // cursor column and the same SGR state, so anything super-linear is a
        // real defect rather than measurement noise.
        final measured = {
          for (final repeats in _repeats) repeats: _ingestOnce(corpus, repeats),
        };
        _printTable(corpus, measured);

        final unit = measured[_repeats.first]!;
        for (final repeats in _repeats) {
          final m = measured[repeats]!;
          final factor = repeats ~/ _repeats.first;
          expect(
            m.droppedBytes,
            0,
            reason: 'a throughput measurement that dropped bytes is measuring '
                'the queue bound instead',
          );
          expect(
            m.chars,
            unit.chars * factor,
            reason: 'the parser consumed exactly the output, $repeats times',
          );
          expect(
            m.linesAllocated,
            unit.linesAllocated * factor,
            reason: 'one BufferLine per line of output, however long the run',
          );
        }
      });
    }

    test('a frame is one parse entry, not one per PTY read', () {
      // The claim `PtyOutputCoalescer` was written for. `flutter_pty` reads
      // 1 KiB at a time, so without coalescing a megabyte of agent output is a
      // thousand `Terminal.write` calls, a thousand UTF-8 decodes and a
      // thousand `notifyListeners()`.
      final m = _ingestOnce(PerfCorpus.plainLog, 16);
      expect(m.writes, m.frames, reason: 'one flush per frame');
      expect(
        m.writes * 8,
        lessThan(m.chunks),
        reason: 'a parse entry must cost far fewer than one per PTY read',
      );
      expect(
        m.notifies,
        m.writes,
        reason: 'the notify is coalesced with the parse it follows',
      );
      // ignore: avoid_print
      print(
        'coalescing · ${m.bytes} bytes · ${m.chunks} PTY reads · '
        '${m.writes} parse entries · ${m.notifies} notifications',
      );
    });

    test('a burst is chunked so no one frame is held by all of it', () {
      // The other half of the coalescer's contract, and the one that decides
      // how long a frame can be held: `cat` of a huge file, or an agent
      // dumping a diff, must be split across frames rather than parsed in one.
      // Everything the pane is holding is offered at once; the cap is what
      // decides how much of it a single `Terminal.write` receives.
      final m = _burst(bytes: kMaxPendingBytes);
      final cap = kMaxFlushBytes < kIngestHotReserveBytes
          ? kMaxFlushBytes
          : kIngestHotReserveBytes;
      // ignore: avoid_print
      print(
        'burst chunking · ${m.bytes} bytes offered at once · ${m.writes} parse '
        'entries · largest ${m.largestWrite} bytes · ${m.droppedBytes} dropped',
      );
      expect(
        m.largestWrite,
        lessThanOrEqualTo(cap),
        reason: 'a flush is capped, so a burst cannot hold one frame open',
      );
      expect(
        m.droppedBytes,
        0,
        reason: 'and the rest is carried, not thrown away',
      );
      expect(m.writes, greaterThan(1), reason: 'so it took more than a frame');
    });
  });

  group('the pane in front does not pay for the panes behind it', () {
    /// Pane 0 is hot; the rest alternate warm and cold, all producing the same
    /// output at the same rate. The tiering promise is that pane 0's numbers do
    /// not move.
    ///
    /// `scale_curve_test.dart` already asserts the *budget's* half of this —
    /// that the shared pool hands the hot reserve out undiluted. This asserts
    /// the half that budget cannot see: the parse entries, the code points and
    /// the buffer churn the hot pane actually performs.
    test('a hot pane costs the same at 1, 10 and 100 panes', () {
      final measured = {for (final n in _scale) n: _ingestAtScale(n)};

      // ignore: avoid_print
      print(
        'N panes | hot writes | hot chars | hot lines | warm chars | '
        'cold chars | background lines',
      );
      for (final n in _scale) {
        final m = measured[n]!;
        // ignore: avoid_print
        print(
          '${n.toString().padLeft(7)} | ${m.hot.writes.toString().padLeft(10)} '
          '| ${m.hot.chars.toString().padLeft(9)} '
          '| ${m.hot.linesAllocated.toString().padLeft(9)} '
          '| ${m.warmChars.toString().padLeft(10)} '
          '| ${m.coldChars.toString().padLeft(10)} '
          '| ${m.backgroundLines.toString().padLeft(16)}',
        );
      }

      final alone = measured[1]!.hot;
      for (final n in _scale) {
        final hot = measured[n]!.hot;
        expect(hot.writes, alone.writes, reason: '$n panes: same parse entries');
        expect(hot.chars, alone.chars, reason: '$n panes: same code points');
        expect(
          hot.linesAllocated,
          alone.linesAllocated,
          reason: '$n panes: same buffer churn',
        );
      }
    });

    test('the background is flat in N, not linear', () {
      final measured = {for (final n in _scale) n: _ingestAtScale(n)};
      expect(measured[1]!.backgroundChars, 0, reason: 'one pane, in front');
      for (final n in _scale) {
        expect(
          measured[n]!.backgroundChars,
          // One fill per frame, plus the one the budget starts with.
          lessThanOrEqualTo((_scaleFrames + 1) * kIngestWarmPoolBytes),
          reason:
              'at $n panes the background still parses out of one pool, so '
              'its total is a pool per frame however many panes there are',
        );
      }
      // Ninety-nine hidden panes and nine both want far more than the pool
      // holds, so the *total* stops moving while the per-pane share collapses.
      // That collapse is the claim: the background stopped costing per pane.
      expect(
        measured[100]!.backgroundChars / 99,
        lessThan(measured[10]!.backgroundChars / 9),
        reason: 'sharing one pool is what makes the total flat',
      );
      expect(
        measured[100]!.backgroundLines / 99,
        lessThan(measured[10]!.backgroundLines / 9),
        reason: 'and the buffer churn behind it is bounded the same way',
      );
    });

    test('a burst costs the panes that are not showing it nothing', () {
      final quiet = _burstReachesOnlyItsOwnPane();
      // ignore: avoid_print
      print(
        'burst fan-out · noisy pane ${quiet.noisyNotifies} notifications · '
        '${quiet.quietPanes} quiet panes ${quiet.quietNotifies} notifications, '
        '${quiet.quietLines} lines, ${quiet.quietGrantedBytes} budget bytes',
      );
      expect(quiet.quietNotifies, 0, reason: 'nothing changed in those panes');
      expect(quiet.quietLines, 0);
      expect(quiet.quietGrantedBytes, 0, reason: 'and they asked for nothing');
      expect(quiet.noisyNotifies, greaterThan(0));
    });
  });

  group('a detached pane', () {
    test('parses a fraction of what arrives, and keeps only its screen', () {
      final m = _coldBurst(seconds: 5);
      // ignore: avoid_print
      print(
        'cold pane · ${m.bytesIn} bytes in · ${m.bytesParsed} bytes parsed '
        '(${(100 * m.bytesParsed / m.bytesIn).toStringAsFixed(1)}%) · '
        '${m.refreshes} screen refreshes · ${m.linesAllocated} lines allocated '
        '· ${m.linesHeld} lines held · ${m.spooled} bytes spooled · '
        '${m.screenDropped} bytes dropped before the screen',
      );
      expect(
        m.bytesParsed * 4,
        lessThan(m.bytesIn),
        reason: 'a pane nobody can see must not parse its own output stream',
      );
      expect(
        m.refreshes,
        lessThanOrEqualTo(6),
        reason: 'at most one screen refresh per second, plus the first',
      );
      expect(
        m.linesHeld,
        kPerfRows,
        reason: 'the screen, and nothing above it',
      );
    });
  });

  group('where the work lands', () {
    test('parse, buffer churn and notify, per corpus', () {
      // ignore: avoid_print
      print(
        'corpus       |    bytes | code points | lines | bytes/line | '
        'KiB alloc/KiB in | decode ns/B | write ns/B | was-runes ns/B | '
        'notify ns/B',
      );
      for (final corpus in PerfCorpus.values) {
        final split = _attribute(corpus);
        // ignore: avoid_print
        print(
          '${corpus.name.padRight(12)} | ${split.bytes.toString().padLeft(8)} '
          '| ${split.chars.toString().padLeft(11)} '
          '| ${split.lines.toString().padLeft(5)} '
          '| ${split.bytesPerLine.toStringAsFixed(1).padLeft(10)} '
          '| ${split.allocRatio.toStringAsFixed(2).padLeft(16)} '
          '| ${split.decodeNsPerByte.toStringAsFixed(2).padLeft(11)} '
          '| ${split.writeNsPerByte.toStringAsFixed(2).padLeft(10)} '
          '| ${split.runesNsPerByte.toStringAsFixed(2).padLeft(10)} '
          '| ${split.notifyNsPerByte.toStringAsFixed(2).padLeft(11)}',
        );
      }
      // Nothing here is asserted: these are wall-clock attributions on a shared
      // machine. The counted half of the same question is asserted above.
    });
  });
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// How many screens of a corpus one measurement ingests. Read as a curve: every
/// counted unit must double with the input.
const _repeats = [2, 4, 8, 16];

/// The three points the scale curve is read at, matching `scale_curve_test`.
const _scale = [1, 10, 100];

/// Bytes one PTY read hands over. `flutter_pty` reads 1 KiB at a time, which is
/// the whole reason there is a coalescer between the pipe and the parser.
const int _ptyReadBytes = 1024;

/// What one frame of a *fast* producer delivers.
///
/// Comfortably under the hot reserve (256 KiB), so a hot pane keeps up exactly
/// and the measurement is of ingest rather than of the queue's drop policy.
const int _feedPerFrame = 64 * 1024;

/// A pane measured through the production path: PTY bytes into a
/// [PtyOutputCoalescer], decoded text into a real [Terminal] at the production
/// scrollback cap, with every unit of work on the way counted.
class _Pane {
  _Pane({
    required TerminalIngestBudget budget,
    required Duration Function() clock,
    required IngestTier tier,
  }) {
    terminal = Terminal(maxLines: kLiveScrollbackMaxLines)
      ..resize(kPerfColumns, kPerfRows);
    coalescer = PtyOutputCoalescer(
      onData: (data) {
        writes++;
        chars += data.length;
        if (data.length > largestWrite) largestWrite = data.length;
        terminal.write(data);
        linesAllocated += _sweepNewLines();
      },
      budget: budget,
      tier: tier,
      scheduleFrameCallback: (callback) => _frame = callback,
      scheduleWatchdog: (_, _) => Object(),
      cancelWatchdog: (_) {},
      // Never idle: sustained output must not take the write-through path meant
      // for an echo at a quiet prompt. That path is measured by
      // `tool/benchmark/input_latency_bench.dart`.
      idleThreshold: const Duration(days: 1),
      monotonicClock: clock,
    );
  }

  late final Terminal terminal;
  late final PtyOutputCoalescer coalescer;
  void Function()? _frame;

  int writes = 0;
  int chars = 0;
  int notifies = 0;
  int linesAllocated = 0;

  /// The biggest single payload ever handed to `Terminal.write` — the longest
  /// one frame can be held by this pane's ingest.
  int largestWrite = 0;

  /// Which `BufferLine` objects this pane has already been charged for.
  ///
  /// Weak, so counting a line does not keep an evicted one alive — which is the
  /// whole point of measuring a bounded scrollback.
  final Expando<bool> _counted = Expando<bool>();

  int get droppedBytes => coalescer.droppedBytes;

  bool get hasPending => coalescer.pendingBytes > 0 || _frame != null;

  /// Puts the pane at the bottom of a full screen and forgets what that cost.
  ///
  /// A fresh `Buffer` is pre-filled with `viewHeight` lines and the cursor
  /// starts at the top, so the first fifty newlines move the cursor instead of
  /// pushing a line. Measuring from there would make the first screen cheaper
  /// than every screen after it and break the linearity the test is asking
  /// about.
  void warmUp() {
    terminal.write(corpusText(PerfCorpus.plainLog));
    terminal.write('\r\n');
    _sweepNewLines();
    terminal.addListener(() => notifies++);
    writes = 0;
    chars = 0;
    notifies = 0;
    linesAllocated = 0;
    largestWrite = 0;
  }

  /// Delivers [bytes] the way the pipe does: [_ptyReadBytes] at a time.
  void feed(Uint8List bytes) {
    for (var at = 0; at < bytes.length; at += _ptyReadBytes) {
      final end = at + _ptyReadBytes;
      coalescer.add(
        Uint8List.sublistView(bytes, at, end < bytes.length ? end : null),
      );
    }
  }

  /// Runs whatever the coalescer is waiting on, as a frame would.
  void runFrame() {
    final callback = _frame;
    _frame = null;
    callback?.call();
  }

  void dispose() => coalescer.dispose();

  /// `BufferLine`s that have appeared since the last sweep.
  ///
  /// Lines are pushed at the **bottom** — `Buffer.index` either pushes or, in
  /// the alternate buffer, scrolls and refills the last row — and are only ever
  /// dropped from the top, so walking up from the bottom until a line we have
  /// already seen is an exact count and stops after the new ones. It is exact
  /// for a saturated ring too, which is why it is done this way rather than by
  /// watching the buffer's height.
  int _sweepNewLines() {
    final lines = terminal.lines;
    var found = 0;
    for (var i = lines.length - 1; i >= 0; i--) {
      final line = lines[i];
      if (_counted[line] ?? false) break;
      _counted[line] = true;
      found++;
    }
    return found;
  }
}

/// A detached pane: bytes go to a bounded spool undecoded, and only its screen
/// is refreshed, out of the shared pool. Exactly `PtyTerminalInstance`'s cold
/// branch.
class _ColdPane {
  _ColdPane({
    required TerminalIngestBudget budget,
    required Duration Function() clock,
  }) {
    terminal = Terminal(maxLines: kLiveScrollbackMaxLines)
      ..resize(kPerfColumns, kPerfRows);
    // Park it the way going cold does, so `ColdScreen` will touch it at all.
    terminal.write(corpusText(PerfCorpus.plainLog));
    park = ScrollbackPark(terminal)..park();
    coldScreen = ColdScreen(
      terminal: terminal,
      park: park,
      budget: budget,
      clock: clock,
    );
    _sweepNewLines();
  }

  late final Terminal terminal;
  late final ScrollbackPark park;
  late final ColdScreen coldScreen;
  final ScrollbackSpool spool = ScrollbackSpool();
  final Expando<bool> _counted = Expando<bool>();

  int bytesIn = 0;
  int linesAllocated = 0;

  void feed(Uint8List bytes) {
    for (var at = 0; at < bytes.length; at += _ptyReadBytes) {
      final end = at + _ptyReadBytes;
      final chunk = Uint8List.sublistView(
        bytes,
        at,
        end < bytes.length ? end : null,
      );
      bytesIn += chunk.length;
      spool.add(chunk);
      coldScreen.add(chunk);
      linesAllocated += _sweepNewLines();
    }
  }

  /// Bytes this pane's screen refresh never got to: `ColdScreen` holds only
  /// [kColdScreenPendingMaxBytes] and drops the front, because only the *end*
  /// of a detached pane is ever displayed.
  int get screenDropped => bytesIn - _parsed - coldScreen.pendingBytes;

  /// Set by the caller from the shared budget, which is the only exact record
  /// of what a cold refresh was allowed to parse.
  int _parsed = 0;
  set parsed(int value) => _parsed = value;

  int get linesHeld => terminal.mainBuffer.lines.length;

  int _sweepNewLines() {
    final lines = terminal.lines;
    var found = 0;
    for (var i = lines.length - 1; i >= 0; i--) {
      final line = lines[i];
      if (_counted[line] ?? false) break;
      _counted[line] = true;
      found++;
    }
    return found;
  }
}

typedef _Measured = ({
  int bytes,
  int chunks,
  int frames,
  int writes,
  int notifies,
  int chars,
  int linesAllocated,
  int largestWrite,
  int droppedBytes,
  int elapsedMicros,
});

/// One hot pane ingesting [repeats] screens of [corpus] through the production
/// path, delivered at [_feedPerFrame] a frame.
_Measured _ingestOnce(PerfCorpus corpus, int repeats) {
  var now = Duration.zero;
  final budget = TerminalIngestBudget(clock: () => now);
  final pane = _Pane(budget: budget, clock: () => now, tier: IngestTier.hot)
    ..warmUp();
  final bytes = _corpusBytes(corpus, repeats);

  final watch = Stopwatch()..start();
  var frames = 0;
  var at = 0;
  while (at < bytes.length || pane.hasPending) {
    if (at < bytes.length) {
      final end = at + _feedPerFrame;
      pane.feed(
        Uint8List.sublistView(bytes, at, end < bytes.length ? end : null),
      );
      at = end;
    }
    now += kIngestRefillInterval;
    pane.runFrame();
    frames++;
  }
  watch.stop();

  final measured = (
    bytes: bytes.length,
    chunks: (bytes.length + _ptyReadBytes - 1) ~/ _ptyReadBytes,
    frames: frames,
    writes: pane.writes,
    notifies: pane.notifies,
    chars: pane.chars,
    linesAllocated: pane.linesAllocated,
    largestWrite: pane.largestWrite,
    droppedBytes: pane.droppedBytes,
    elapsedMicros: watch.elapsedMicroseconds,
  );
  pane.dispose();
  return measured;
}

/// One hot pane handed [bytes] of output all at once, then drained frame by
/// frame — `cat hugefile`, or an agent dumping a diff in one go.
_Measured _burst({required int bytes}) {
  var now = Duration.zero;
  final budget = TerminalIngestBudget(clock: () => now);
  final pane = _Pane(budget: budget, clock: () => now, tier: IngestTier.hot)
    ..warmUp();
  final payload = _corpusBytes(
    PerfCorpus.plainLog,
    (bytes / _corpusBytes(PerfCorpus.plainLog, 1).length).ceil(),
  );
  final offered = Uint8List.sublistView(payload, 0, bytes);

  final watch = Stopwatch()..start();
  pane.feed(offered);
  var frames = 0;
  while (pane.hasPending && frames < 1000) {
    now += kIngestRefillInterval;
    pane.runFrame();
    frames++;
  }
  watch.stop();

  final measured = (
    bytes: offered.length,
    chunks: (offered.length + _ptyReadBytes - 1) ~/ _ptyReadBytes,
    frames: frames,
    writes: pane.writes,
    notifies: pane.notifies,
    chars: pane.chars,
    linesAllocated: pane.linesAllocated,
    largestWrite: pane.largestWrite,
    droppedBytes: pane.droppedBytes,
    elapsedMicros: watch.elapsedMicroseconds,
  );
  pane.dispose();
  return measured;
}

typedef _ScaleMeasured = ({
  ({int writes, int chars, int linesAllocated}) hot,
  int warmChars,
  int coldChars,
  int backgroundChars,
  int backgroundLines,
});

/// Frames one scale measurement runs for. Long enough for the queues to reach
/// steady state, short enough that no warm pane's queue reaches
/// [kMaxPendingBytes] and starts dropping.
const int _scaleFrames = 20;

/// [panes] panes all producing at once: pane 0 hot, the rest alternating warm
/// and cold, on one shared budget.
_ScaleMeasured _ingestAtScale(int panes) {
  const frames = _scaleFrames;
  var now = Duration.zero;
  final budget = TerminalIngestBudget(clock: () => now);
  final hot = _Pane(budget: budget, clock: () => now, tier: IngestTier.hot)
    ..warmUp();
  final warm = <_Pane>[];
  final cold = <_ColdPane>[];
  for (var i = 1; i < panes; i++) {
    if (i.isOdd) {
      warm.add(
        _Pane(budget: budget, clock: () => now, tier: IngestTier.warm)..warmUp(),
      );
    } else {
      cold.add(_ColdPane(budget: budget, clock: () => now));
    }
  }

  final bytes = _corpusBytes(PerfCorpus.plainLog, 8);
  final perFrame = _feedPerFrame;
  for (var frame = 0; frame < frames; frame++) {
    final at = (frame * perFrame) % bytes.length;
    final end = at + perFrame;
    final slice = Uint8List.sublistView(
      bytes,
      at,
      end < bytes.length ? end : null,
    );
    hot.feed(slice);
    for (final pane in warm) {
      pane.feed(slice);
    }
    for (final pane in cold) {
      pane.feed(slice);
    }
    now += kIngestRefillInterval;
    hot.runFrame();
    for (final pane in warm) {
      pane.runFrame();
    }
  }

  // The cold tier's parse is read off the shared budget rather than off the
  // panes: a cold pane's own queue *drops* what it cannot draw (it only ever
  // shows the last screen), so counting what left that queue would charge it
  // for bytes nothing ever parsed.
  final warmChars = warm.fold<int>(0, (sum, pane) => sum + pane.chars);
  final coldChars = budget.granted[IngestTier.cold]!;
  final measured = (
    hot: (
      writes: hot.writes,
      chars: hot.chars,
      linesAllocated: hot.linesAllocated,
    ),
    warmChars: warmChars,
    coldChars: coldChars,
    backgroundChars: warmChars + coldChars,
    backgroundLines:
        warm.fold<int>(0, (sum, pane) => sum + pane.linesAllocated) +
        cold.fold<int>(0, (sum, pane) => sum + pane.linesAllocated),
  );
  hot.dispose();
  for (final pane in warm) {
    pane.dispose();
  }
  return measured;
}

typedef _FanOut = ({
  int noisyNotifies,
  int quietPanes,
  int quietNotifies,
  int quietLines,
  int quietGrantedBytes,
});

/// One pane bursts; nine others, all hot and all listening, receive nothing.
_FanOut _burstReachesOnlyItsOwnPane() {
  const others = 9;
  var now = Duration.zero;
  final budget = TerminalIngestBudget(clock: () => now);
  final noisy = _Pane(budget: budget, clock: () => now, tier: IngestTier.hot)
    ..warmUp();
  final quiet = [
    for (var i = 0; i < others; i++)
      _Pane(budget: budget, clock: () => now, tier: IngestTier.hot)..warmUp(),
  ];
  final before = budget.granted[IngestTier.hot]!;

  final bytes = _corpusBytes(PerfCorpus.plainLog, 8);
  var at = 0;
  while (at < bytes.length || noisy.hasPending) {
    if (at < bytes.length) {
      final end = at + _feedPerFrame;
      noisy.feed(
        Uint8List.sublistView(bytes, at, end < bytes.length ? end : null),
      );
      at = end;
    }
    now += kIngestRefillInterval;
    noisy.runFrame();
    for (final pane in quiet) {
      pane.runFrame();
    }
  }

  final measured = (
    noisyNotifies: noisy.notifies,
    quietPanes: others,
    quietNotifies: quiet.fold<int>(0, (sum, pane) => sum + pane.notifies),
    quietLines: quiet.fold<int>(0, (sum, pane) => sum + pane.linesAllocated),
    // Everything the hot tier was granted, less what the noisy pane took: the
    // quiet panes must not have asked the shared budget for a byte.
    quietGrantedBytes: budget.granted[IngestTier.hot]! - before - noisy.chars,
  );
  noisy.dispose();
  for (final pane in quiet) {
    pane.dispose();
  }
  return measured;
}

typedef _ColdMeasured = ({
  int bytesIn,
  int bytesParsed,
  int refreshes,
  int linesAllocated,
  int linesHeld,
  int spooled,
  int screenDropped,
});

/// A detached pane taking a burst over [seconds] of simulated time.
_ColdMeasured _coldBurst({required int seconds}) {
  var now = Duration.zero;
  final budget = TerminalIngestBudget(clock: () => now);
  final pane = _ColdPane(budget: budget, clock: () => now);
  final bytes = _corpusBytes(PerfCorpus.plainLog, 8);

  final framesPerSecond =
      const Duration(seconds: 1).inMicroseconds ~/
      kIngestRefillInterval.inMicroseconds;
  for (var frame = 0; frame < seconds * framesPerSecond; frame++) {
    final at = (frame * 4096) % bytes.length;
    final end = at + 4096;
    pane.feed(
      Uint8List.sublistView(bytes, at, end < bytes.length ? end : null),
    );
    now += kIngestRefillInterval;
  }

  pane.parsed = budget.granted[IngestTier.cold]!;
  return (
    bytesIn: pane.bytesIn,
    bytesParsed: budget.granted[IngestTier.cold]!,
    refreshes: pane.coldScreen.refreshes,
    linesAllocated: pane.linesAllocated,
    linesHeld: pane.linesHeld,
    spooled: pane.spool.length,
    screenDropped: pane.screenDropped,
  );
}

typedef _Attribution = ({
  int bytes,
  int chars,
  int lines,
  double bytesPerLine,
  double allocRatio,
  double decodeNsPerByte,
  double writeNsPerByte,
  double runesNsPerByte,
  double notifyNsPerByte,
});

/// Splits one corpus's ingest into the layers it passes through.
///
/// The counted columns are exact. The nanosecond columns are wall clock on
/// whatever machine ran the suite and are printed, never asserted; they exist
/// to say *which* of the counted units is the expensive one.
_Attribution _attribute(PerfCorpus corpus) {
  const repeats = 8;
  final bytes = _corpusBytes(corpus, repeats);
  final text = const Utf8Decoder().convert(bytes);

  // Bytes off the pipe to a Dart string.
  final decode = _fastest(
    () => const Utf8Decoder(allowMalformed: true).convert(bytes),
  );

  // What `ByteConsumer.add` used to do to every flush before one code point of
  // it was looked at, kept here as the baseline the rewrite is measured
  // against: whenever this column stops being far larger than the gap between
  // `write` and the rest, `String.runes` has crept back in.
  final runes = _fastest(() => text.runes.toList(growable: false));

  // Parse plus buffer, with nothing listening.
  final silent = Terminal(maxLines: kLiveScrollbackMaxLines)
    ..resize(kPerfColumns, kPerfRows);
  final write = _fastest(() => silent.write(text));

  // The same, carrying the two listeners a live pane really has: the sessions
  // controller's dirty marker and a mounted view's `markNeedsLayout`.
  final watched = Terminal(maxLines: kLiveScrollbackMaxLines)
    ..resize(kPerfColumns, kPerfRows);
  var sink = 0;
  watched
    ..addListener(() => sink++)
    ..addListener(() => sink++);
  final notified = _fastest(() => watched.write(text));
  expect(sink, greaterThan(0), reason: 'the listeners really did run');

  // Counted, on a pane driven the same way the linearity test drives one.
  final counted = _ingestOnce(corpus, repeats);
  return (
    bytes: counted.bytes,
    chars: counted.chars,
    lines: counted.linesAllocated,
    bytesPerLine: counted.bytes / counted.linesAllocated,
    // Cell memory the buffer allocated for every byte that arrived. A line is
    // `_calcCapacity(200) * 4` 32-bit words — 4 KiB at this width — whatever
    // the line actually says.
    allocRatio: counted.linesAllocated * 4096 / counted.bytes,
    decodeNsPerByte: decode / bytes.length,
    writeNsPerByte: write / bytes.length,
    runesNsPerByte: runes / bytes.length,
    notifyNsPerByte: (notified - write) / bytes.length,
  );
}

/// Nanoseconds for the fastest of several runs of [body], after warming it up.
///
/// The minimum rather than the mean: every source of error on a shared machine
/// — another agent's build, a GC pause, the scheduler — makes a run *slower*,
/// so the fastest run is the closest thing to the work itself. These numbers
/// are printed and never asserted; they exist to say which counted unit is the
/// expensive one.
double _fastest(void Function() body, {int warmUp = 3, int reps = 7}) {
  for (var i = 0; i < warmUp; i++) {
    body();
  }
  var best = double.infinity;
  for (var i = 0; i < reps; i++) {
    final watch = Stopwatch()..start();
    body();
    watch.stop();
    final ns = watch.elapsedMicroseconds * 1000.0;
    if (ns < best) best = ns;
  }
  return best;
}

/// [repeats] screens of [corpus], joined so each one starts at column 0 — so
/// every repeat is identical work and the curve means something.
Uint8List _corpusBytes(PerfCorpus corpus, int repeats) {
  final screen = corpusText(corpus);
  final buffer = StringBuffer();
  for (var i = 0; i < repeats; i++) {
    buffer
      ..write(screen)
      ..write('\r\n');
  }
  return const Utf8Encoder().convert(buffer.toString());
}

void _printTable(PerfCorpus corpus, Map<int, _Measured> measured) {
  // ignore: avoid_print
  print(
    '${corpus.name} · screens |    bytes | PTY reads | parse entries | '
    'code points | lines | wall ms',
  );
  for (final repeats in _repeats) {
    final m = measured[repeats]!;
    // ignore: avoid_print
    print(
      '${repeats.toString().padLeft(18)} | ${m.bytes.toString().padLeft(8)} '
      '| ${m.chunks.toString().padLeft(9)} '
      '| ${m.writes.toString().padLeft(13)} '
      '| ${m.chars.toString().padLeft(11)} '
      '| ${m.linesAllocated.toString().padLeft(5)} '
      '| ${(m.elapsedMicros / 1000).toStringAsFixed(1).padLeft(7)}',
    );
  }
}
