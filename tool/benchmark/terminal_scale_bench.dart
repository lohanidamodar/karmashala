import 'dart:io';

import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:chitragupta/src/features/terminal/data/pty_output_coalescer.dart';
import 'package:chitragupta/src/features/terminal/domain/scrollback_limits.dart';
import 'package:chitragupta/src/features/terminal/domain/terminal_profile.dart';
import 'package:chitragupta/src/features/terminal/presentation/terminal_panel.dart';
import 'package:chitragupta/src/features/terminal/presentation/terminal_pane_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../test/features/terminal/fake_instance.dart';
import '../../test/terminal/perf/corpora.dart';

/// Benchmark — NOT part of `flutter test`'s default run. Run it on demand:
///
///   flutter test tool/benchmark/terminal_scale_bench.dart
///
/// The evidence for the scale target in `docs/ARCHITECTURE.md`: **100 sessions
/// with a terminal each, responsive while the user types in one of them.**
///
/// Opens N process-free panes through the real `TerminalSessionsController`,
/// fills every one of them with output, then measures the three things that
/// scale with N. Run at N = 1, 10, 100 and read it as a **curve**: what must not
/// change is the slope. A cost that is flat in N is safe; one that is linear in
/// N is a freeze waiting for a hundredth pane.
///
/// Wall-clock figures are machine-dependent and are printed, not asserted —
/// same contract as `tool/benchmark/paint_bench.dart`.
void main() {
  const paneColumns = 120;
  const paneRows = 40;

  /// Lines written into every pane. Enough that the durable byte cap bites (so
  /// a save is a realistic save) without 100 panes needing a workstation.
  const linesPerPane = 600;

  /// A container of fake (process-free) panes over a real in-memory database,
  /// so the save path is the production one.
  ({
    ProviderContainer container,
    TerminalSessionsController controller,
    AppDatabase database,
  })
  openPanes(int count) {
    final database = AppDatabase.memory();
    final container = fakeTerminalContainer(database: database);
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final chunk = '${corpusText(PerfCorpus.colorizedLs, columns: paneColumns, rows: paneRows)}\r\n';
    for (var i = 0; i < count; i++) {
      final tabId = controller.openTab(TerminalProfile.powerShell);
      final paneId = container
          .read(terminalSessionsControllerProvider)
          .tabs
          .firstWhere((t) => t.id == tabId)
          .layout
          .panes
          .single;
      final terminal = controller.instanceFor(paneId)!.terminal
        ..resize(paneColumns, paneRows);
      for (var written = 0; written < linesPerPane; written += paneRows) {
        terminal.write(chunk);
      }
    }
    return (
      container: container,
      controller: controller,
      database: database,
    );
  }

  Duration median(List<Duration> samples) {
    samples.sort();
    return samples[samples.length ~/ 2];
  }

  int rssMegabytes() => ProcessInfo.currentRss ~/ (1024 * 1024);

  test('cost curve at N = 1, 10, 100 panes', () {
    // ignore: avoid_print
    print(
      'N panes | autosave tick | keystroke encode | echo write | '
      'listeners/chunk | RSS',
    );
    for (final n in [1, 10, 100]) {
      final baselineRss = rssMegabytes();
      final opened = openPanes(n);
      final controller = opened.controller;
      final container = opened.container;

      // (1) The autosave tick: the timer that walks every dirty pane. This is
      // the cost the scale target most directly forbids being linear in N.
      final tickSamples = <Duration>[];
      for (var i = 0; i < 3; i++) {
        // Dirty every pane again, as a round of output would.
        for (final tab in container
            .read(terminalSessionsControllerProvider)
            .tabs) {
          controller.instanceFor(tab.layout.panes.single)?.terminal.write(
            'tick $i\r\n',
          );
        }
        final sw = Stopwatch()..start();
        controller.saveDirtyScrollback();
        sw.stop();
        tickSamples.add(sw.elapsed);
      }

      // (2) and (3): what one keystroke in the *focused* pane costs while all N
      // panes hold output — the encode out to the PTY, and the echo coming back
      // through the coalescer into the buffer.
      final focusedPane = container
          .read(terminalSessionsControllerProvider)
          .tabs
          .last
          .layout
          .panes
          .single;
      final focused = controller.instanceFor(focusedPane)!.terminal;
      var listenerCalls = 0;
      // Every pane's terminal carries the controller's dirty-tracking listener;
      // count the fan-out one output chunk causes across the whole workspace.
      void countOne() => listenerCalls++;
      focused.addListener(countOne);

      const runs = 20000;
      final encode = Stopwatch()..start();
      for (var i = 0; i < runs; i++) {
        focused.charInput(0x61);
      }
      encode.stop();

      final echo = Stopwatch()..start();
      for (var i = 0; i < runs; i++) {
        focused.write('a');
      }
      echo.stop();
      focused.removeListener(countOne);

      final rss = rssMegabytes();
      // ignore: avoid_print
      print(
        '${n.toString().padLeft(7)} | '
        '${'${median(tickSamples).inMicroseconds}us'.padLeft(13)} | '
        '${'${(encode.elapsedMicroseconds / runs).toStringAsFixed(3)}us'.padLeft(16)} | '
        '${'${(echo.elapsedMicroseconds / runs).toStringAsFixed(3)}us'.padLeft(10)} | '
        '${(listenerCalls / runs).toStringAsFixed(0).padLeft(15)} | '
        '${rss}MB (+${rss - baselineRss})',
      );

      container.dispose();
      opened.database.close();
    }
  }, timeout: const Timeout(Duration(minutes: 20)));

  test('memory budget at the live scrollback cap', () {
    // What the scale target actually asks to be reasoned about: 100 panes at
    // kLiveScrollbackMaxLines, not one. Measured on a single pane and
    // multiplied, because filling a hundred to the cap is the thing being
    // costed, not something to do casually inside a benchmark.
    final before = rssMegabytes();
    final probe = FakeTerminalInstance(
      id: 'probe',
      title: 'probe',
      profileId: 'p',
    );
    probe.terminal.resize(paneColumns, paneRows);
    final chunk = '${corpusText(PerfCorpus.colorizedLs, columns: paneColumns, rows: paneRows)}\r\n';
    for (var i = 0; i < kLiveScrollbackMaxLines; i += paneRows) {
      probe.terminal.write(chunk);
    }
    final after = rssMegabytes();
    // ignore: avoid_print
    print(
      'one pane at $kLiveScrollbackMaxLines lines x $paneColumns cols: '
      '~${after - before}MB resident; '
      '100 panes would be ~${(after - before) * 100}MB',
    );
    probe.dispose();
    expect(after, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 20)));

  testWidgets('mounted view cost curve at N = 1, 10, 100 tabs', (tester) async {
    // T6: `IndexedStack` is preservation, not virtualization. Every open tab
    // keeps a mounted `PaneLayoutView`/`TerminalView` subtree — render objects,
    // layouts, focus and scroll clients — whether or not it can be seen. What
    // is measured here is what that costs and what bounding it saves.
    //
    // `skipOffstage: false` is load-bearing: `_RawIndexedStackElement`
    // overrides `debugVisitOnstageChildren` to visit only the selected child,
    // so the default finder reports one mounted pane however many are really
    // there. The render-object count is the honest second opinion.
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final chunk =
        '${corpusText(PerfCorpus.plainLog, columns: 80, rows: 24)}\r\n';

    Future<void> measure(int n, {required bool report}) async {
      final database = AppDatabase.memory();
      final container = fakeTerminalContainer(database: database);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final tabIds = <String>[];
      for (var i = 0; i < n; i++) {
        final tabId = controller.openTab(TerminalProfile.powerShell);
        tabIds.add(tabId);
        final paneId = container
            .read(terminalSessionsControllerProvider)
            .tabs
            .firstWhere((t) => t.id == tabId)
            .layout
            .panes
            .single;
        controller.instanceFor(paneId)?.terminal.write(chunk);
      }

      final first = Stopwatch()..start();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: TerminalPaneStack())),
        ),
      );
      await tester.pump();
      first.stop();

      final mounted = tester
          .widgetList(find.byType(TerminalPaneView, skipOffstage: false))
          .length;
      var renderObjects = 0;
      void count(Element element) {
        if (element.renderObject != null) renderObjects++;
        element.visitChildren(count);
      }

      tester.binding.rootElement!.visitChildren(count);

      // Switching round-robin from the back of the tab list: with a bounded
      // mounted set this is the worst case, because every switch remounts.
      final switches = <Duration>[];
      for (var i = 0; i < 5; i++) {
        final sw = Stopwatch()..start();
        controller.activateTab(tabIds[(tabIds.length - 1 - i) % tabIds.length]);
        await tester.pump();
        sw.stop();
        switches.add(sw.elapsed);
      }

      if (report) {
        // ignore: avoid_print
        print(
          '${n.toString().padLeft(6)} | '
          '${mounted.toString().padLeft(13)} | '
          '${renderObjects.toString().padLeft(14)} | '
          '${'${first.elapsedMilliseconds}ms'.padLeft(12)} | '
          '${'${(median(switches).inMicroseconds / 1000).toStringAsFixed(2)}ms'.padLeft(10)}',
        );
      }

      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      database.close();
    }

    // Warm-up: the first pump of the process pays for font resolution and
    // shader setup, which is not what any of these numbers are about.
    await measure(2, report: false);

    // ignore: avoid_print
    print(
      'N tabs | mounted views | render objects | first layout | tab switch',
    );
    for (final n in [1, 10, 100]) {
      await measure(n, report: true);
    }
  }, timeout: const Timeout(Duration(minutes: 20)));

  test('the coalescer does no work for a pane nobody is watching', () {
    // A hidden pane schedules no frames, so its output is drained by the
    // watchdog. At 100 panes that is 100 timers a second; count them.
    var timers = 0;
    final coalescer = PtyOutputCoalescer(
      onData: (_) {},
      scheduleFrameCallback: (_) {},
      scheduleWatchdog: (delay, callback) {
        timers++;
        return Object();
      },
      cancelWatchdog: (_) {},
    );
    for (var i = 0; i < 100; i++) {
      coalescer.add([0x61]);
    }
    // ignore: avoid_print
    print('100 output chunks with no frames ever: $timers watchdog timers');
    coalescer.dispose();
    expect(timers, greaterThan(0));
  });
}
