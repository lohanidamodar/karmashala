import 'dart:typed_data';

import 'package:chitragupta/src/features/terminal/data/pty_output_coalescer.dart';
import 'package:chitragupta/src/features/terminal/data/scrollback_spool.dart';
import 'package:chitragupta/src/features/terminal/data/terminal_ingest_budget.dart';
import 'package:chitragupta/src/features/terminal/domain/ingest_tier.dart';
import 'package:flutter_test/flutter_test.dart';

/// Visibility-aware ingestion: one global parse budget, and a pane nobody can
/// see does not get to spend the frame.
///
/// The measured problem (`tool/benchmark/terminal_ingest_bench.dart`): with 100
/// panes producing output, one frame's ingestion took 62 ms against a 16.7 ms
/// budget, linear in the number of panes, because every pane carried its own
/// 256 KiB flush cap and its own 16 ms watchdog. Per-pane limits cannot protect
/// the active pane — no pane knows what the other ninety-nine are doing.
void main() {
  Uint8List bytes(int count) => Uint8List(count)..fillRange(0, count, 0x61);

  group('the shared budget', () {
    test('the hot pane draws on a reserve the pool cannot be emptied of', () {
      var now = Duration.zero;
      final budget = TerminalIngestBudget(
        hotReserveBytes: 1000,
        warmPoolBytes: 100,
        clock: () => now,
      );

      // Ninety-nine warm panes take everything there is.
      for (var i = 0; i < 99; i++) {
        budget.take(IngestTier.warm, 1000);
      }
      expect(budget.warmPoolRemaining, 0);

      // The active pane is unaffected, which is the entire point.
      expect(budget.take(IngestTier.hot, 1000), 1000);
    });

    test('every warm pane together is bounded by one pool', () {
      var now = Duration.zero;
      final budget = TerminalIngestBudget(
        warmPoolBytes: 1000,
        clock: () => now,
      );

      var granted = 0;
      for (var i = 0; i < 100; i++) {
        granted += budget.take(IngestTier.warm, 500);
      }

      expect(
        granted,
        1000,
        reason: 'a hundred hidden panes cost one pool, not a hundred of them',
      );
      expect(budget.granted[IngestTier.warm], 1000);
    });

    test('the pool refills once per interval, not per call', () {
      var now = Duration.zero;
      final budget = TerminalIngestBudget(
        warmPoolBytes: 100,
        refillInterval: const Duration(milliseconds: 16),
        clock: () => now,
      );

      expect(budget.take(IngestTier.warm, 100), 100);
      expect(budget.take(IngestTier.warm, 100), 0);

      now += const Duration(milliseconds: 16);
      expect(budget.take(IngestTier.warm, 100), 100);
      expect(budget.refills, 1);
    });

    test('a cold pane is never granted anything', () {
      final budget = TerminalIngestBudget();

      expect(budget.take(IngestTier.cold, 1024), 0);
      expect(
        budget.warmPoolRemaining,
        kIngestWarmPoolBytes,
        reason: 'and it does not consume the pool by asking',
      );
    });
  });

  group('the coalescer under a budget', () {
    /// A coalescer with fully driven schedulers, so a flush happens exactly
    /// when the test says so.
    ({PtyOutputCoalescer coalescer, List<String> written, void Function() frame})
    make({
      required TerminalIngestBudget budget,
      required IngestTier tier,
      int maxPendingBytes = kMaxPendingBytes,
    }) {
      final written = <String>[];
      void Function()? pending;
      final coalescer = PtyOutputCoalescer(
        onData: written.add,
        budget: budget,
        tier: tier,
        maxPendingBytes: maxPendingBytes,
        scheduleFrameCallback: (callback) => pending = callback,
        scheduleWatchdog: (delay, callback) => Object(),
        cancelWatchdog: (_) {},
        idleThreshold: const Duration(days: 1),
      );
      return (
        coalescer: coalescer,
        written: written,
        frame: () {
          final callback = pending;
          pending = null;
          callback?.call();
        },
      );
    }

    test('a warm pane writes only what the pool allowed, and keeps the rest', () {
      var now = Duration.zero;
      final budget = TerminalIngestBudget(
        warmPoolBytes: 100,
        clock: () => now,
      );
      final pane = make(budget: budget, tier: IngestTier.warm);

      pane.coalescer.add(bytes(500));
      pane.frame();

      expect(pane.written.single.length, 100);
      expect(
        pane.coalescer.pendingBytes,
        400,
        reason: 'the rest is queued, not dropped',
      );

      now += const Duration(milliseconds: 16);
      pane.frame();
      expect(pane.written.last.length, 100);
    });

    test('a hot pane is unaffected by warm panes having drained the pool', () {
      var now = Duration.zero;
      final budget = TerminalIngestBudget(
        hotReserveBytes: 1024,
        warmPoolBytes: 10,
        clock: () => now,
      );
      final warm = make(budget: budget, tier: IngestTier.warm);
      final hot = make(budget: budget, tier: IngestTier.hot);

      warm.coalescer.add(bytes(500));
      warm.frame();
      hot.coalescer.add(bytes(500));
      hot.frame();

      expect(warm.written.single.length, 10);
      expect(hot.written.single.length, 500, reason: 'the reserve is its own');
    });

    test('a hidden pane waits longer between drains than a visible one', () {
      final delays = <Duration>[];
      PtyOutputCoalescer at(IngestTier tier) => PtyOutputCoalescer(
        onData: (_) {},
        tier: tier,
        scheduleFrameCallback: (_) {},
        scheduleWatchdog: (delay, callback) {
          delays.add(delay);
          return Object();
        },
        cancelWatchdog: (_) {},
        idleThreshold: const Duration(days: 1),
      );

      at(IngestTier.hot).add(bytes(1));
      at(IngestTier.warm).add(bytes(1));

      expect(delays, [
        const Duration(milliseconds: 16),
        kHiddenCoalescerWatchdog,
      ]);
    });

    test('a starved queue is bounded, and says how much it lost', () {
      var now = Duration.zero;
      final budget = TerminalIngestBudget(warmPoolBytes: 0, clock: () => now);
      final pane = make(
        budget: budget,
        tier: IngestTier.warm,
        maxPendingBytes: 100,
      );

      for (var i = 0; i < 10; i++) {
        pane.coalescer.add(bytes(50));
      }

      expect(pane.coalescer.pendingBytes, 100);
      expect(pane.coalescer.droppedBytes, 400);
    });

    test('becoming hot re-arms a pane that was waiting on the slow watchdog', () {
      // Activation must not make the user wait out a hidden pane's cadence.
      final delays = <Duration>[];
      final coalescer = PtyOutputCoalescer(
        onData: (_) {},
        tier: IngestTier.warm,
        scheduleFrameCallback: (_) {},
        scheduleWatchdog: (delay, callback) {
          delays.add(delay);
          return Object();
        },
        cancelWatchdog: (_) {},
        idleThreshold: const Duration(days: 1),
      );

      coalescer.add(bytes(1));
      expect(delays, [kHiddenCoalescerWatchdog]);

      coalescer.tier = IngestTier.hot;

      expect(delays, [kHiddenCoalescerWatchdog, const Duration(milliseconds: 16)]);
    });

    test('taking the queue leaves nothing behind to parse', () {
      final pane = make(
        budget: TerminalIngestBudget(),
        tier: IngestTier.hot,
      );
      pane.coalescer.add(bytes(200));

      final taken = pane.coalescer.takePending();

      expect(taken.length, 200);
      expect(pane.coalescer.pendingBytes, 0);
      pane.frame();
      expect(pane.written, isEmpty, reason: 'nothing was parsed on the way out');
    });
  });

  group('the spool', () {
    test('holds what it is given, in order', () {
      final spool = ScrollbackSpool(maxBytes: 100);

      spool
        ..add(Uint8List.fromList('ab'.codeUnits))
        ..add(Uint8List.fromList('cd'.codeUnits));

      expect(String.fromCharCodes(spool.drain()), 'abcd');
      expect(spool.isEmpty, isTrue);
    });

    test('drops the oldest when full, and counts it', () {
      final spool = ScrollbackSpool(maxBytes: 4);

      spool
        ..add(Uint8List.fromList('abcd'.codeUnits))
        ..add(Uint8List.fromList('ef'.codeUnits));

      expect(String.fromCharCodes(spool.drain()), 'cdef');
      expect(spool.droppedBytes, 2);
    });

    test('a single oversized chunk is trimmed to the tail', () {
      final spool = ScrollbackSpool(maxBytes: 3);

      spool.add(Uint8List.fromList('abcdef'.codeUnits));

      expect(String.fromCharCodes(spool.drain()), 'def');
      expect(spool.droppedBytes, 3);
    });

    test('reset forgets the loss as well as the bytes', () {
      final spool = ScrollbackSpool(maxBytes: 2)
        ..add(Uint8List.fromList('abcd'.codeUnits))
        ..reset();

      expect(spool.droppedBytes, 0);
      expect(spool.length, 0);
    });
  });
}
