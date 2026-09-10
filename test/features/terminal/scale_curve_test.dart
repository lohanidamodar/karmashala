import 'dart:typed_data';

import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/explorer/application/session_context.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/pty_output_coalescer.dart';
import 'package:karmashala/src/features/terminal/data/terminal_ingest_budget.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_pane_view.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../terminal/perf/corpora.dart';
import 'fake_instance.dart';

/// The scale target as a **gate**: N = 1 / 10 / 100 panes, asserted as a curve.
///
/// the design note"Scale target — 100 live terminals" says what must
/// not happen — work proportional to all panes, unbounded per-pane memory, a
/// listener storm — and `tool/benchmark/terminal_scale_bench.dart` reports the
/// wall-clock version of it. But a benchmark nobody runs cannot catch a
/// regression, and wall-clock numbers cannot be asserted on a shared machine.
///
/// So this is the **fast tier**, and it runs on every `flutter test`. It
/// measures the same three things the benchmark does — what the focused pane's
/// keystroke costs, what the parse budget spends, and what a layout holds in
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

    test(
      'what the whole app parses per frame is bounded however many panes',
      () {
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
      },
    );
  });

  group('memory: a layout holds a floor per pane, not a buffer per pane', () {
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

  group('switching tabs: the panes that are not involved are not rebuilt', () {
    /// The owner's report against 1.1.4: "switching tab is heavy too, it might
    /// be recomputing everything even the hidden things".
    ///
    /// Two mechanisms could produce that, and both are counted here. A switch
    /// re-derives every pane's ingest tier, so it could **parse** — promotion
    /// out of `cold` rebuilds a buffer from its parked window and its spool.
    /// And the stack rebuilds, so it could rebuild the view of every pane the
    /// mounted budget is holding rather than only the two tabs involved.
    ///
    /// Widget identity is the probe for the second: widgets are immutable, so
    /// a pane whose `TerminalPaneView` is the *same object* after the switch is
    /// a pane the switch did not rebuild.
    /// The curve's own points, minus one: a switch needs somewhere to switch
    /// to, and at N = 1 there is nowhere.
    const switchScale = [2, 10, 100];

    testWidgets('a switch parses nothing and rebuilds two panes, at every N', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final chunk =
          '${corpusText(PerfCorpus.plainLog, columns: 80, rows: 24)}\r\n';
      final rebuilt = <int, int>{};
      final parsed = <int, int>{};

      for (final n in switchScale) {
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

        /// Every mounted pane view, by the pane it draws. `skipOffstage: false`
        /// because `IndexedStack` hides the ones this test is about.
        Map<String, TerminalPaneView> mountedViews() => {
          for (final view in tester.widgetList<TerminalPaneView>(
            find.byType(TerminalPaneView, skipOffstage: false),
          ))
            view.instance.id: view,
        };

        int totalLines() {
          var lines = 0;
          for (final tab
              in container.read(terminalSessionsControllerProvider).tabs) {
            for (final paneId in tab.layout.panes) {
              lines += controller
                  .instanceFor(paneId)!
                  .terminal
                  .buffer
                  .lines
                  .length;
            }
          }
          return lines;
        }

        final before = mountedViews();
        final linesBefore = totalLines();
        // Both tabs are already mounted, so this is a plain switch rather than
        // a remount — the case the user does dozens of times an hour.
        final target = tabIds.firstWhere(
          (id) =>
              id !=
              container.read(terminalSessionsControllerProvider).activeTabId,
        );
        controller.activateTab(target);
        await tester.pump();

        final after = mountedViews();
        rebuilt[n] = [
          for (final entry in after.entries)
            if (!identical(before[entry.key], entry.value)) entry.key,
        ].length;
        parsed[n] = totalLines() - linesBefore;

        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        database.close();
      }

      // ignore: avoid_print
      print('N tabs | pane views rebuilt by one switch | lines parsed');
      for (final n in switchScale) {
        // ignore: avoid_print
        print(
          '${n.toString().padLeft(6)} | ${rebuilt[n]!.toString().padLeft(30)} | '
          '${parsed[n]}',
        );
      }

      for (final n in switchScale) {
        expect(
          parsed[n],
          0,
          reason:
              'a switch between two open tabs moves panes between warm and '
              'hot, and neither tier parses anything on the way — only '
              'promotion out of cold rebuilds a buffer, and a pane with a tab '
              'is never cold',
        );
      }
      expect(
        rebuilt[100],
        rebuilt[10],
        reason:
            'what a switch rebuilds is bounded by the mounted set, so it must '
            'not grow with the number of tabs behind it',
      );
    });

    testWidgets('switching to an evicted tab rebuilds its view, not its '
        'buffer', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final database = AppDatabase.memory();
      final container = fakeTerminalContainer(database: database);
      addTearDown(container.dispose);
      addTearDown(database.close);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );

      // Two past the budget, so the tabs opened first are certain to have been
      // evicted by the time the last one is active.
      final tabIds = <String>[];
      final paneIds = <String>[];
      for (var i = 0; i < kMountedTabBudget + 2; i++) {
        final tabId = controller.openTab(TerminalProfile.powerShell);
        tabIds.add(tabId);
        final paneId = container
            .read(terminalSessionsControllerProvider)
            .tabs
            .firstWhere((tab) => tab.id == tabId)
            .layout
            .panes
            .single;
        paneIds.add(paneId);
        controller
            .instanceFor(paneId)!
            .terminal
            .write('tab $i output\r\n' * 40);
      }

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: TerminalPaneStack())),
        ),
      );
      await tester.pump();

      Set<String> mountedPanes() => {
        for (final view in tester.widgetList<TerminalPaneView>(
          find.byType(TerminalPaneView, skipOffstage: false),
        ))
          view.instance.id,
      };

      final evicted = paneIds.firstWhere(
        (paneId) => !mountedPanes().contains(paneId),
      );
      final index = paneIds.indexOf(evicted);
      final instance = controller.instanceFor(evicted)!;
      final terminal = instance.terminal;

      controller.activateTab(tabIds[index]);
      await tester.pump();

      expect(
        mountedPanes(),
        contains(evicted),
        reason: 'the tab being switched to is always mounted',
      );
      expect(
        mountedPanes(),
        hasLength(kMountedTabBudget),
        reason: 'and the budget is still the ceiling afterwards',
      );
      // The design claim, tested rather than asserted in prose: eviction takes
      // the widgets and leaves the buffer. Coming back builds a view over the
      // pane's own `Terminal` — the same object, with the same scrollback in
      // it — rather than replaying anything into a new one.
      expect(controller.instanceFor(evicted), same(instance));
      expect(instance.terminal, same(terminal));
      expect(
        terminal.mainBuffer.getText(),
        contains('tab $index output'),
        reason: 'the history was never re-parsed because it never left',
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
    // T8's remainder, now **closed**. Three consumers used to watch the whole
    // `TerminalSessionsState` and be told about every process that died
    // anywhere: `app/shell/status_bar.dart` (for `detached.length`),
    // `explorer/application/session_context.dart`
    // (`activePaneSessionIdProvider`, which answered by walking every session
    // row), and the workbench's tab strip (for the liveness dot on each tab).
    //
    // The first two were narrowed with a `select`; the strip could not be,
    // because it genuinely draws liveness — so the watch moved *into the
    // chip*, one tab at a time. Both halves are asserted below as counts.

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

    test('a pane dying costs the session lookup nothing', () async {
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
          0,
          reason:
              'the narrowed watch is not told about liveness at all, so there '
              'is nothing to recompute and nothing to scan',
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

      // The claim, now that the three watches are narrowed: a background pane
      // dying costs the session lookup **nothing**, at any N. It used to cost
      // one full scan of every session row per exit — ten scans over a
      // thousand rows at N = 100 — for an answer that cannot have changed,
      // because liveness says nothing about which pane is focused.
      for (final n in scale) {
        expect(
          walked[n],
          0,
          reason: 'no session row is walked because a process somewhere died',
        );
      }
    });

    testWidgets('a pane dying rebuilds its own tab chip and no other', (
      tester,
    ) async {
      // The strip's own half of T8, counted the way
      // `explorer_rebuild_triggers_test.dart` counts the Explorer's: a rebuilt
      // chip is a **new widget instance**, so identity is the counter. It needs
      // no instrumentation inside the widgets and cannot be fooled by a chip
      // that rebuilt to the same pixels.
      //
      // The window is deliberately wider than a hundred tabs need. The strip
      // virtualises, and a virtualised list would report only the dozen chips
      // it happened to have built — the count wanted here is the whole strip.
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(13000, 800);
      addTearDown(tester.view.reset);

      /// Every chip on screen, by the title that identifies its tab.
      Map<String, TerminalTabChip> chips() => {
        for (final chip in tester.widgetList<TerminalTabChip>(
          find.byType(TerminalTabChip),
        ))
          chip.title: chip,
      };

      final rebuiltAtTheExit = <int, int>{};
      final rebuiltElsewhere = <int, int>{};
      final exitCount = <int, int>{};

      for (final n in scale) {
        final database = AppDatabase.memory();
        final container = ProviderContainer(
          overrides: fakeTerminalOverrides(database: database),
        );
        final controller = container.read(
          terminalSessionsControllerProvider.notifier,
        );
        final tabIds = [
          for (var i = 0; i < n; i++)
            controller.openTab(
              TerminalProfile.powerShell,
              workingDirectory:
                  r'C:\src\p'
                  '$i',
            ),
        ];
        // Opening activates, so the strip would otherwise start scrolled to
        // the far end with the last tab in front.
        controller.activateTab(tabIds.first);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: Scaffold(body: WorkbenchView())),
          ),
        );
        await tester.pumpAndSettle();

        final before = chips();
        expect(before.length, n, reason: 'every tab draws a chip');

        // Ten panes at the far end of the strip lose their process — a build
        // finishing, an ssh session dropping, an agent ending its turn. The
        // tab in front is never one of them.
        final dying = n < 10 ? n : 10;
        final tabs = container.read(terminalSessionsControllerProvider).tabs;
        final died = <String>{};
        for (var i = tabs.length - dying; i < tabs.length; i++) {
          final tab = tabs[i];
          died.add(controller.titleForTab(tab.id));
          (controller.instanceFor(tab.layout.panes.single)!
                      as FakeTerminalInstance)
                  .livenessNotifier
                  .value =
              PaneLiveness.exited;
          await tester.pump();
        }

        final after = chips();
        var atTheExit = 0;
        var elsewhere = 0;
        for (final entry in after.entries) {
          if (identical(entry.value, before[entry.key])) continue;
          died.contains(entry.key) ? atTheExit++ : elsewhere++;
        }
        rebuiltAtTheExit[n] = atTheExit;
        rebuiltElsewhere[n] = elsewhere;
        exitCount[n] = dying;

        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        database.close();
      }

      // ignore: avoid_print
      print(
        'N tabs | exits | chips rebuilt at the exit | chips rebuilt elsewhere',
      );
      for (final n in scale) {
        // ignore: avoid_print
        print(
          '${n.toString().padLeft(6)} | ${exitCount[n]!.toString().padLeft(5)} | '
          '${rebuiltAtTheExit[n]!.toString().padLeft(24)} | '
          '${rebuiltElsewhere[n]}',
        );
      }

      for (final n in scale) {
        expect(
          rebuiltAtTheExit[n],
          exitCount[n],
          reason:
              'the dot still moves: every tab that lost a process redraws, at '
              'every N',
        );
        expect(
          rebuiltElsewhere[n],
          0,
          reason:
              'and nothing else does — the strip is no longer told about a '
              'process dying in a tab it is not drawing',
        );
      }
    });
  });
}

/// A [SessionDao] that counts what `activePaneSessionIdProvider` asks of it.
///
/// Subclassed rather than faked so the rest of the dao behaves exactly as the
/// app's does; only the active-tab query is instrumented.
class _ProbeSessionDao extends SessionDao {
  _ProbeSessionDao(super.database, this._rows);

  final List<Session> _rows;

  int scans = 0;
  int rowsWalked = 0;

  @override
  List<Session> getByPaneIds(Iterable<String> paneIds) {
    scans++;
    final ids = paneIds.toSet();
    final matches = _rows.where((row) => ids.contains(row.paneId)).toList();
    rowsWalked += matches.length;
    return matches;
  }
}
