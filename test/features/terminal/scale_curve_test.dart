import 'dart:typed_data';

import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/explorer/application/session_context.dart';
import 'package:chitragupta/src/features/sessions/application/session_providers.dart';
import 'package:chitragupta/src/features/sessions/data/session_dao.dart';
import 'package:chitragupta/src/features/sessions/domain/session.dart';
import 'package:chitragupta/src/features/sessions/domain/session_status.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:chitragupta/src/features/terminal/data/pty_output_coalescer.dart';
import 'package:chitragupta/src/features/terminal/data/terminal_ingest_budget.dart';
import 'package:chitragupta/src/features/terminal/domain/ingest_tier.dart';
import 'package:chitragupta/src/features/terminal/domain/mounted_tabs.dart';
import 'package:chitragupta/src/features/terminal/domain/pane_liveness.dart';
import 'package:chitragupta/src/features/terminal/domain/terminal_profile.dart';
import 'package:chitragupta/src/features/terminal/presentation/terminal_pane_view.dart';
import 'package:chitragupta/src/features/terminal/presentation/terminal_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../terminal/perf/corpora.dart';
import 'fake_instance.dart';

/// The scale target as a **gate**: N = 1 / 10 / 100 panes, asserted as a curve.
///
/// `docs/ARCHITECTURE.md` §"Scale target — 100 live terminals" says what must
/// not happen — work proportional to all panes, unbounded per-pane memory, a
/// listener storm — and `tool/benchmark/terminal_scale_bench.dart` reports the
/// wall-clock version of it. But a benchmark nobody runs cannot catch a
/// regression, and wall-clock numbers cannot be asserted on a shared machine.
///
/// So this is the **fast tier**, and it runs on every `flutter test`. It
/// measures the same three things the benchmark does — what the focused pane's
/// keystroke costs, what the parse budget spends, and what a workspace holds in
/// memory — but counts them instead of timing them, at the same three values of
/// N, and asserts the *shape*:
///
/// * a count that must be **flat** in N, where the old design was linear;
/// * a count that must be **identical** at N = 1 and N = 100, where the pane in
///   front is concerned.
///
/// Wall-clock figures are printed beside the assertions for the record and are
/// deliberately not asserted; that half of the curve lives in the benchmark,
/// which is excluded from the suite by living outside `test/` rather than by a
/// tag — `flutter test` never globs `tool/`. Run it with
/// `flutter test tool/benchmark/terminal_scale_bench.dart`.
void main() {
  /// The three points the curve is read at. One pane is the "did we make the
  /// single-pane case worse" control; a hundred is the target.
  const scale = [1, 10, 100];

  group('ingestion: the pane in front is not diluted by the ones behind', () {
    /// One screen of output per pane per frame — enough that a hundred panes
    /// together want far more than the shared pool holds, which is the only
    /// regime in which the pool's bound is observable at all.
    const chunkBytes = 8192;

    /// Long enough for the queues to reach steady state, short enough that no
    /// warm pane's queue reaches [kMaxPendingBytes] and starts dropping — which
    /// would make the totals a measure of the queue bound rather than the pool.
    const frames = 30;

    /// Drives [panes] coalescers — one hot, the rest warm — through [frames]
    /// refill intervals on one shared budget, and reports what each tier was
    /// actually allowed to decode.
    ({int hot, int warm}) drive(int panes) {
      var now = Duration.zero;
      final budget = TerminalIngestBudget(clock: () => now);
      final chunk = Uint8List(chunkBytes)..fillRange(0, chunkBytes, 0x61);
      final pending = List<void Function()?>.filled(panes, null);
      final coalescers = <PtyOutputCoalescer>[];
      var hot = 0;
      var warm = 0;

      for (var i = 0; i < panes; i++) {
        final index = i;
        final isHot = i == 0;
        coalescers.add(
          PtyOutputCoalescer(
            onData: (data) => isHot ? hot += data.length : warm += data.length,
            budget: budget,
            tier: isHot ? IngestTier.hot : IngestTier.warm,
            scheduleFrameCallback: (callback) => pending[index] = callback,
            scheduleWatchdog: (_, _) => Object(),
            cancelWatchdog: (_) {},
            // Every flush goes through the budget: the write-through path for
            // an idle pane's echo is a different measurement.
            idleThreshold: const Duration(days: 1),
            monotonicClock: () => now,
          ),
        );
      }

      for (var frame = 0; frame < frames; frame++) {
        for (final coalescer in coalescers) {
          coalescer.add(chunk);
        }
        now += kIngestRefillInterval;
        for (var i = 0; i < panes; i++) {
          final callback = pending[i];
          pending[i] = null;
          callback?.call();
        }
      }
      for (final coalescer in coalescers) {
        coalescer.dispose();
      }
      return (hot: hot, warm: warm);
    }

    test('the focused pane decodes the same bytes at N = 1 and N = 100', () {
      final measured = {for (final n in scale) n: drive(n)};
      // ignore: avoid_print
      print('N panes | hot bytes | warm bytes | total per frame');
      for (final n in scale) {
        final m = measured[n]!;
        // ignore: avoid_print
        print(
          '${n.toString().padLeft(7)} | ${m.hot.toString().padLeft(9)} | '
          '${m.warm.toString().padLeft(10)} | '
          '${((m.hot + m.warm) / frames).round()}',
        );
      }

      final alone = measured[1]!.hot;
      expect(alone, frames * chunkBytes, reason: 'it got everything it asked');
      for (final n in scale) {
        expect(
          measured[n]!.hot,
          alone,
          reason:
              'the reserve is what the user is waiting on; $n panes of '
              'background must not shrink it by a byte',
        );
      }
    });

    test('every hidden pane put together is flat in N, not linear', () {
      final measured = {for (final n in scale) n: drive(n)};

      expect(measured[1]!.warm, 0, reason: 'one pane, and it is in front');
      // Both are saturated — ninety-nine panes and nine both want more than the
      // pool holds — so the totals are equal rather than merely bounded. That
      // equality is the claim: the cost of the background stopped being
      // per-pane.
      expect(measured[10]!.warm, frames * kIngestWarmPoolBytes);
      expect(measured[100]!.warm, measured[10]!.warm);
      expect(
        measured[100]!.warm / 99,
        lessThan(measured[10]!.warm / 9),
        reason: 'sharing one pool is what makes the total flat',
      );
    });

    test('what the whole app parses per frame is bounded however many panes', () {
      for (final n in scale) {
        final m = drive(n);
        expect(
          (m.hot + m.warm) / frames,
          lessThanOrEqualTo(
            (kIngestHotReserveBytes + kIngestWarmPoolBytes).toDouble(),
          ),
          reason: 'one reserve plus one pool, at every N',
        );
      }
    });
  });

  group('memory: a workspace holds a floor per pane, not a buffer per pane', () {
    /// Deep enough that the parked window is real history rather than the
    /// screen, and that closing the tab detaches rather than releases an idle
    /// shell.
    const linesPerPane = 200;

    test('a detached pane keeps its screen and nothing above it', () {
      final resident = <int, int>{};
      final perPane = <int, int>{};

      for (final n in scale) {
        final container = fakeTerminalContainer();
        final controller = container.read(
          terminalSessionsControllerProvider.notifier,
        );
        final tabIds = [
          for (var i = 0; i < n; i++)
            controller.openTab(TerminalProfile.powerShell),
        ];
        final panes = [
          for (final tab
              in container.read(terminalSessionsControllerProvider).tabs)
            tab.layout.panes.single,
        ];
        for (final paneId in panes) {
          final terminal = controller.instanceFor(paneId)!.terminal;
          for (var i = 0; i < linesPerPane; i++) {
            terminal.write('output line $i\r\n');
          }
        }

        final activeTabId = container
            .read(terminalSessionsControllerProvider)
            .activeTabId;
        for (final tabId in tabIds) {
          if (tabId != activeTabId) controller.closeTab(tabId);
        }

        var lines = 0;
        var detachedLines = 0;
        var detached = 0;
        for (final paneId in panes) {
          final instance = controller.instanceFor(paneId)!;
          final held = instance.terminal.mainBuffer.lines.length;
          lines += held;
          if (instance case final FakeTerminalInstance fake
              when fake.ingestTier == IngestTier.cold) {
            detached++;
            detachedLines += held;
            expect(
              fake.parkedScrollback,
              contains('output line ${linesPerPane - 1}'),
              reason: 'the history is held as text, not thrown away',
            );
          }
        }
        resident[n] = lines;
        perPane[n] = detached == 0 ? 0 : detachedLines ~/ detached;
        container.dispose();
      }

      // ignore: avoid_print
      print('N panes | parsed lines | per detached pane');
      for (final n in scale) {
        // ignore: avoid_print
        print(
          '${n.toString().padLeft(7)} | ${resident[n]!.toString().padLeft(12)} | '
          '${perPane[n]}',
        );
      }

      expect(perPane[1], 0, reason: 'nothing was detached');
      expect(
        perPane[100],
        perPane[10],
        reason:
            'the floor is the viewport, and a viewport does not grow with '
            'the number of panes beside it',
      );
      // The whole hundred cost less parsed scrollback than ten live panes did
      // before they were detached — which is the point of the tier.
      expect(resident[100]! - resident[10]!, lessThan(linesPerPane * 90));
    });
  });

  group('views: the mounted set is bounded, so a hundred tabs cost eight', () {
    testWidgets('mounted views and render objects are flat above the budget', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final chunk =
          '${corpusText(PerfCorpus.plainLog, columns: 80, rows: 24)}\r\n';
      final mountedViews = <int, int>{};
      final renderObjects = <int, int>{};

      for (final n in scale) {
        final database = AppDatabase.memory();
        final container = fakeTerminalContainer(database: database);
        final controller = container.read(
          terminalSessionsControllerProvider.notifier,
        );
        for (var i = 0; i < n; i++) {
          final tabId = controller.openTab(TerminalProfile.powerShell);
          final paneId = container
              .read(terminalSessionsControllerProvider)
              .tabs
              .firstWhere((tab) => tab.id == tabId)
              .layout
              .panes
              .single;
          controller.instanceFor(paneId)!.terminal.write(chunk);
        }

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: Scaffold(body: TerminalPaneStack())),
          ),
        );
        await tester.pump();

        // `skipOffstage: false` is load-bearing: `IndexedStack` hides its
        // unselected children from the default finder, which would report one
        // mounted pane however many really are.
        mountedViews[n] = tester
            .widgetList(find.byType(TerminalPaneView, skipOffstage: false))
            .length;
        var objects = 0;
        void count(Element element) {
          if (element.renderObject != null) objects++;
          element.visitChildren(count);
        }

        tester.binding.rootElement!.visitChildren(count);
        renderObjects[n] = objects;

        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        database.close();
      }

      // ignore: avoid_print
      print('N tabs | mounted views | render objects');
      for (final n in scale) {
        // ignore: avoid_print
        print(
          '${n.toString().padLeft(6)} | ${mountedViews[n]!.toString().padLeft(13)} | '
          '${renderObjects[n]}',
        );
      }

      for (final n in scale) {
        expect(
          mountedViews[n],
          n < kMountedTabBudget ? n : kMountedTabBudget,
          reason: 'the budget is the ceiling, not a suggestion',
        );
      }
      expect(
        renderObjects[100],
        renderObjects[10],
        reason:
            'above the budget the tree is the same tree, so a hundred tabs '
            'lay out what ten do',
      );
    });
  });

  group('fan-out: one pane producing output is one pane rebuilding', () {
    test('a write reaches only its own pane at every N', () {
      for (final n in scale) {
        final container = fakeTerminalContainer();
        final controller = container.read(
          terminalSessionsControllerProvider.notifier,
        );
        for (var i = 0; i < n; i++) {
          controller.openTab(TerminalProfile.powerShell);
        }
        final panes = [
          for (final tab
              in container.read(terminalSessionsControllerProvider).tabs)
            tab.layout.panes.single,
        ];

        var notified = 0;
        void count() => notified++;
        for (final paneId in panes) {
          controller.instanceFor(paneId)!.terminal.addListener(count);
        }
        controller.instanceFor(panes.last)!.terminal.write('one chunk\r\n');
        for (final paneId in panes) {
          controller.instanceFor(paneId)!.terminal.removeListener(count);
        }

        expect(
          notified,
          1,
          reason:
              'a provider that fans out per output chunk is fine at one pane '
              'and pathological at $n',
        );
        container.dispose();
      }
    });

    test('a keystroke in the focused pane costs the same at N = 1 and 100', () {
      // Wall clock, printed rather than asserted: this machine is shared and
      // the absolute numbers mean nothing off it. What the assertions above
      // pin is the *work*; this is the human-readable half of the same curve.
      const runs = 5000;
      // ignore: avoid_print
      print('N panes | keystroke encode | echo write');
      for (final n in scale) {
        final container = fakeTerminalContainer();
        final controller = container.read(
          terminalSessionsControllerProvider.notifier,
        );
        for (var i = 0; i < n; i++) {
          controller.openTab(TerminalProfile.powerShell);
        }
        final state = container.read(terminalSessionsControllerProvider);
        final focused = controller
            .instanceFor(
              state.tabs
                  .firstWhere((tab) => tab.id == state.activeTabId)
                  .layout
                  .panes
                  .single,
            )!
            .terminal;

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

        // ignore: avoid_print
        print(
          '${n.toString().padLeft(7)} | '
          '${'${(encode.elapsedMicroseconds / runs).toStringAsFixed(3)}us'.padLeft(16)} | '
          '${(echo.elapsedMicroseconds / runs).toStringAsFixed(3)}us',
        );
        container.dispose();
      }
    });
  });

  group('publication: what one pane exiting costs everything else', () {
    // T8's remainder, **measured rather than changed**. Three consumers still
    // watch the whole `TerminalSessionsState`, and all three are outside this
    // branch's territory:
    //
    // * `app/shell/status_bar.dart` — to read `detached.length`;
    // * `app/shell/workbench.dart` — to notice whether the selected session
    //   still has a pane;
    // * `explorer/application/session_context.dart` —
    //   `activePaneSessionIdProvider`, which additionally answers by walking
    //   **every session row**, so a process exiting anywhere is a full scan.
    //
    // What is pinned here is only what must stay true however they are
    // narrowed; the rest is printed, so whoever narrows them has a before.

    Session sessionRow(int i) => Session(
      id: 's$i',
      repositoryId: 'r',
      agentInstallationId: 'a',
      title: 'session $i',
      useWorktree: false,
      status: SessionStatus.running,
      createdAt: DateTime.utc(2026),
      paneId: 'pane-$i',
    );

    test('a full session scan per exit is what a wide watch costs', () async {
      final scans = <int, int>{};
      final walked = <int, int>{};
      final wideNotifications = <int, int>{};
      final exitCount = <int, int>{};

      for (final n in scale) {
        final database = AppDatabase.memory();
        final dao = _ProbeSessionDao(database, [
          for (var i = 0; i < n; i++) sessionRow(i),
        ]);
        // Built with the override in it rather than layered on a child
        // container: this codebase declares no provider `dependencies`, so a
        // child's override never reaches a provider the parent already
        // initialised, and the counter would read zero however wrong the code.
        final container = ProviderContainer(
          overrides: [
            ...fakeTerminalOverrides(database: database),
            sessionDaoProvider.overrideWithValue(dao),
          ],
        );
        final controller = container.read(
          terminalSessionsControllerProvider.notifier,
        );
        for (var i = 0; i < n; i++) {
          controller.openTab(TerminalProfile.powerShell);
        }
        final panes = [
          for (final tab
              in container.read(terminalSessionsControllerProvider).tabs)
            tab.layout.panes.single,
        ];

        var wide = 0;
        var topology = 0;
        final onWide = container.listen(
          terminalSessionsControllerProvider,
          (_, _) => wide++,
        );
        final onTopology = container.listen(
          terminalSessionsControllerProvider.select((s) => s.tabs),
          (_, _) => topology++,
        );
        // Kept alive so it really recomputes; an unlistened provider is
        // disposed and would scan nothing however wide its watch.
        final onActive = container.listen(
          activePaneSessionIdProvider,
          (_, _) {},
        );
        await container.pump();
        dao.scans = 0;
        dao.rowsWalked = 0;
        wide = 0;
        topology = 0;

        // Ten unrelated background panes lose their process — a build
        // finishing, an ssh session dropping, an agent ending its turn.
        final dying = panes.length < 10 ? panes.length : 10;
        for (var i = 0; i < dying; i++) {
          (controller.instanceFor(panes[i])! as FakeTerminalInstance)
                  .livenessNotifier
                  .value =
              PaneLiveness.exited;
          await container.pump();
        }

        scans[n] = dao.scans;
        walked[n] = dao.rowsWalked;
        wideNotifications[n] = wide;
        exitCount[n] = dying;

        expect(
          topology,
          0,
          reason:
              'a pane dying changes no topology, and the narrow providers '
              'already know it — this is the control',
        );
        expect(
          dao.scans,
          lessThanOrEqualTo(dying),
          reason:
              'at most one scan per exit today, and fewer once the watch is '
              'narrowed — this bound survives the fix',
        );

        onWide.close();
        onTopology.close();
        onActive.close();
        container.dispose();
        database.close();
      }

      // ignore: avoid_print
      print(
        'N panes | exits | wide-watch notifications | session scans | rows walked',
      );
      for (final n in scale) {
        // ignore: avoid_print
        print(
          '${n.toString().padLeft(7)} | ${exitCount[n]!.toString().padLeft(5)} | '
          '${wideNotifications[n]!.toString().padLeft(24)} | '
          '${scans[n]!.toString().padLeft(13)} | ${walked[n]}',
        );
      }

      // The shape, and the only claim that needs to hold: the *work* one
      // background pane's death causes grows with the number of sessions, not
      // with what changed. Three widgets watch the same wide state, so the
      // notification column is paid three times over in the shell.
      expect(walked[100]!, greaterThan(walked[10]!));
    });
  });
}

/// A [SessionDao] that counts what `activePaneSessionIdProvider` asks of it.
///
/// Subclassed rather than faked so the rest of the dao behaves exactly as the
/// app's does; only the one method the wide watch drives is instrumented.
class _ProbeSessionDao extends SessionDao {
  _ProbeSessionDao(super.database, this._rows);

  final List<Session> _rows;

  int scans = 0;
  int rowsWalked = 0;

  @override
  List<Session> getAll() {
    scans++;
    rowsWalked += _rows.length;
    return _rows;
  }
}
