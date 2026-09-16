import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/terminal/data/scrollback_codec.dart';
import 'package:karmashala/src/features/terminal/data/terminal_layout_dao.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

import '../../test/terminal/perf/corpora.dart';

/// Benchmark — NOT part of `flutter test`'s default run. Run it on demand:
///
///   flutter test tool/benchmark/scrollback_save_bench.dart
///
/// What the 20 s scrollback autosave costs on the UI isolate, per pane, for a
/// realistically full buffer. The autosave calls
/// `TerminalSessionsController.saveDirtyScrollback()`, which for every dirty
/// pane runs `encodeScrollback` and then a synchronous SQLite `UPDATE` — both
/// on the main isolate, both while the user is typing.
///
/// The four corpora are the Loop 26 painter corpora reused as *input* only;
/// nothing here reads or writes the painter's budgets or goldens.
void main() {
  /// A pane's live buffer filled to [lines] with [corpus] content.
  Terminal fill(PerfCorpus corpus, {int lines = kLiveScrollbackMaxLines}) {
    final terminal = Terminal(maxLines: lines)..resize(kPerfColumns, kPerfRows);
    final chunk = '${corpusText(corpus)}\r\n';
    for (var written = 0; written < lines; written += kPerfRows) {
      terminal.write(chunk);
    }
    return terminal;
  }

  Duration median(List<Duration> samples) {
    samples.sort();
    return samples[samples.length ~/ 2];
  }

  test('encodeScrollback per pane, by corpus', () {
    for (final corpus in PerfCorpus.values) {
      final terminal = fill(corpus);
      // One warm-up, then five measured.
      encodeScrollback(terminal);
      final samples = <Duration>[];
      var bytes = 0;
      for (var i = 0; i < 5; i++) {
        final sw = Stopwatch()..start();
        bytes = encodeScrollback(terminal).length;
        sw.stop();
        samples.add(sw.elapsed);
      }
      // The same encode with the byte cap lifted: the difference between this
      // and the measured cost above is what enforcing the cap costs.
      final noCap = <Duration>[];
      var uncapped = 0;
      for (var i = 0; i < 5; i++) {
        final sw = Stopwatch()..start();
        uncapped = encodeScrollback(terminal, maxBytes: 1 << 30).length;
        sw.stop();
        noCap.add(sw.elapsed);
      }
      // ignore: avoid_print
      print(
        '$corpus: median=${median(samples).inMicroseconds}us '
        '(encode-only ${median(noCap).inMicroseconds}us, '
        'so cap enforcement = '
        '${median(samples).inMicroseconds - median(noCap).inMicroseconds}us) '
        'stored=${bytes ~/ 1024}KB uncapped=${uncapped ~/ 1024}KB '
        '(cap ${kDurableScrollbackMaxBytes ~/ 1024}KB)',
      );
      expect(samples, isNotEmpty);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('encodeScrollback cost as the encoding crosses the byte cap', () {
    // The cap is enforced by dropping one leading line at a time and re-joining
    // what is left, so the cost of enforcing it grows with how far over the cap
    // the encoding started. Sweep the overshoot.
    for (final lines in [500, 1000, 1500, 2000]) {
      final terminal = fill(PerfCorpus.adversarial, lines: lines);
      encodeScrollback(terminal);
      final samples = <Duration>[];
      for (var i = 0; i < 3; i++) {
        final sw = Stopwatch()..start();
        encodeScrollback(terminal);
        sw.stop();
        samples.add(sw.elapsed);
      }
      final uncapped = encodeScrollback(terminal, maxBytes: 1 << 30).length;
      // ignore: avoid_print
      print(
        '$lines lines of 24-bit colour: median=${median(samples).inMilliseconds}ms '
        '(${median(samples).inMicroseconds}us) uncapped=${uncapped ~/ 1024}KB',
      );
      expect(samples, isNotEmpty);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('the SQLite half of a save', () {
    final db = AppDatabase.memory();
    final dao = TerminalLayoutDao(db);
    final terminal = fill(PerfCorpus.colorizedLs);
    final encoded = encodeScrollback(terminal);
    dao.saveScrollback('missing-pane', encoded);
    final samples = <Duration>[];
    for (var i = 0; i < 20; i++) {
      final sw = Stopwatch()..start();
      dao.saveScrollback('missing-pane', encoded);
      sw.stop();
      samples.add(sw.elapsed);
    }
    // ignore: avoid_print
    print(
      'saveScrollback(${encoded.length ~/ 1024}KB): '
      'median=${median(samples).inMicroseconds}us',
    );
    db.close();
    expect(samples, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
