import 'dart:io';

import 'package:chitragupta/src/features/terminal/data/pty_launch.dart';
import 'package:chitragupta/src/features/terminal/data/terminal_instance.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:xterm/xterm.dart';

/// Streams a real ~5 MB log through a real PTY into a real [TerminalView] and
/// reports the frame timings. Windows desktop only — this is not part of
/// `flutter test`; run it with `flutter test integration_test/... -d windows`.
///
/// The strict 16.7 ms budget is *reported*, not asserted: wall clock on a
/// developer machine is too noisy to gate on. The asserted, machine-independent
/// budget is the draw-op count in `test/terminal/perf/draw_ops_test.dart`.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('streaming a 5 MB log keeps frames inside budget', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp('chitragupta_perf');
    final log = File('${directory.path}/big.log');
    final filler = 'x' * 180;
    final sink = log.openWrite();
    for (var i = 0; i < 25000; i++) {
      sink.writeln('$i $filler');
    }
    await sink.close();
    // ignore: avoid_print
    print(
      'log is ${(await log.length() / (1024 * 1024)).toStringAsFixed(1)} MB',
    );

    // An *interactive* shell, so the same session can be typed into once the
    // burst is over — that is what the keystroke-echo budget needs.
    final instance = PtyTerminalInstance(
      id: 'perf',
      title: 'perf',
      launch: PtyLaunch(
        executable: 'powershell.exe',
        arguments: ['-NoLogo', '-NoProfile'],
      ),
    );

    final timings = <FrameTiming>[];
    void collect(List<FrameTiming> reported) => timings.addAll(reported);
    binding.addTimingsCallback(collect);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(
            instance.terminal,
            controller: instance.controller,
            textStyle: const TerminalStyle(
              fontSize: 13,
              fontFamily: 'Consolas',
            ),
            hardwareKeyboardOnly: true,
          ),
        ),
      ),
    );

    // Let the shell reach its prompt before loading it up.
    await _pumpUntil(
      tester,
      () => instance.terminal.buffer.lines.length > 1,
      timeout: const Duration(seconds: 30),
    );

    instance.terminal.onOutput?.call('Get-Content -Raw "${log.path}"\r');

    var lastLines = 0;
    var idleFrames = 0;
    await _pumpUntil(tester, () {
      final lines = instance.terminal.buffer.lines.length;
      if (lines == lastLines) return ++idleFrames > 60 && lines > 1000;
      idleFrames = 0;
      lastLines = lines;
      return false;
    }, timeout: const Duration(seconds: 90));

    binding.removeTimingsCallback(collect);

    // Keystroke -> echo, immediately after the burst: type one character and
    // count the frames until the shell's echo reaches the buffer.
    final beforeEcho = instance.terminal.buffer.lines.length;
    var echoFrames = 0;
    final echoWatch = Stopwatch()..start();
    instance.terminal.onOutput?.call('Z');
    while (echoWatch.elapsedMilliseconds < 5000) {
      await tester.pump(const Duration(milliseconds: 16));
      echoFrames++;
      final cursorLine = instance.terminal.buffer.absoluteCursorY;
      if (cursorLine < instance.terminal.buffer.lines.length &&
          instance.terminal.buffer.lines[cursorLine].getText().contains('Z')) {
        break;
      }
    }
    echoWatch.stop();
    // ignore: avoid_print
    print(
      'keystroke echo: ${echoWatch.elapsedMilliseconds}ms over $echoFrames '
      'pumped frames (buffer was $beforeEcho lines)',
    );

    instance.dispose();
    await directory.delete(recursive: true);

    final totals =
        timings.map((t) => t.totalSpan.inMicroseconds).toList(growable: false)
          ..sort();
    expect(totals, isNotEmpty, reason: 'no frames were produced');

    final median = totals[totals.length ~/ 2] / 1000.0;
    final p95 = totals[(totals.length * 95) ~/ 100] / 1000.0;
    // ignore: avoid_print
    print(
      'streamed ${instance.terminal.buffer.lines.length} lines · '
      'frames=${totals.length} median=${median}ms p95=${p95}ms',
    );

    expect(
      p95,
      lessThan(50.0),
      reason: 'gross regression guard, not the 16.7 ms budget',
    );
  }, timeout: const Timeout(Duration(minutes: 4)));
}

/// Pumps 16 ms frames until [done] or [timeout].
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 16));
    if (done()) return;
  }
}
