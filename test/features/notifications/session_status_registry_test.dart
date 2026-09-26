import 'dart:async';
import 'dart:math' as math;

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala_agent_reporting/status.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/notifications/application/session_status_registry.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

import '../../support/fixtures.dart';

/// A state-file source with no disk behind it, so a 500-session fairness proof
/// runs in milliseconds and can count exactly what the registry asked for.
class _FakeStateSource extends AgentStateFileStatusSource {
  _FakeStateSource();

  /// path → the record the transcript's last line decodes to.
  final Map<String, Map<String, Object?>> records = {};

  /// path → its mtime, so a test can make one file change.
  final Map<String, DateTime> modified = {};

  /// Paths whose read fails, for the previously-failing priority tier.
  final Set<String> broken = {};

  int calls = 0;
  int reads = 0;
  int inFlight = 0;
  int peakInFlight = 0;
  Duration delay = Duration.zero;

  @override
  Future<StateFileSnapshot?> probe(
    String filePath, {
    StateFileSnapshot? known,
  }) async {
    calls++;
    inFlight++;
    peakInFlight = math.max(peakInFlight, inFlight);
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (broken.contains(filePath)) return null;
      final record = records[filePath];
      if (record == null) return null;
      final mtime = modified[filePath] ?? testTime;
      if (known != null && known.modified == mtime) return known;
      reads++;
      return StateFileSnapshot(
        modified: mtime,
        size: record.length,
        record: record,
      );
    } finally {
      inFlight--;
    }
  }
}

/// A clock the tests move forward.
class _MovableClock implements Clock {
  _MovableClock(this.now);
  DateTime now;
  @override
  DateTime nowUtc() => now.toUtc();
}

void main() {
  late AgentHookReports reports;
  late AgentHookReceiver receiver;
  late AgentStatusService service;
  late _FakeStateSource source;
  late _MovableClock clock;
  late List<WatchedSession> watched;
  late Set<String> visible;

  setUp(() {
    clock = _MovableClock(testTime);
    reports = AgentHookReports();
    receiver = AgentHookReceiver(
      registry: AgentRegistry.builtIn,
      reports: reports,
      clock: clock,
    );
    service = AgentStatusService(
      registry: AgentRegistry.builtIn,
      hookReports: reports,
      clock: clock,
    );
    source = _FakeStateSource();
    watched = [];
    visible = {};
  });

  SessionStatusRegistry build({
    int probeBudget = kStatusProbeBudget,
    int probeConcurrency = kStatusProbeConcurrency,
    Future<Map<String, String>> Function()? resolveTranscripts,
    List<String> Function(WatchedSession)? readTail,
    Future<void> Function(bool mayScanStores)? onCycle,
  }) => SessionStatusRegistry(
    statusService: service,
    agents: AgentRegistry.builtIn,
    loadSessions: () => watched,
    clock: clock,
    stateFileSource: source,
    probeBudget: probeBudget,
    probeConcurrency: probeConcurrency,
    resolveTranscripts: resolveTranscripts,
    readTail: readTail,
    visibleSessionIds: () => visible,
    onCycle: onCycle,
  );

  /// [count] imported sessions, each with its own transcript saying `idle`.
  void addTranscriptSessions(int count, {String prefix = 'cli'}) {
    for (var i = 0; i < count; i++) {
      final path = 'store/$prefix-$i.jsonl';
      source.records[path] = {'type': 'assistant'};
      watched.add(
        WatchedSession(
          key: AgentSessionKey(AgentIds.claudeCode, '$prefix-$i'),
          label: 'Session $i',
          openId: 'row-$prefix-$i',
          imported: true,
          stateFilePath: path,
        ),
      );
    }
  }

  /// [count] native sessions whose only source is a hook.
  void addHookedSessions(int count, {String event = 'PreToolUse'}) {
    for (var i = 0; i < count; i++) {
      watched.add(
        WatchedSession(
          key: AgentSessionKey(AgentIds.claudeCode, 'hook-$i'),
          label: 'Hooked $i',
          openId: 'row-hook-$i',
          imported: false,
        ),
      );
      receiver.handle(
        agentId: AgentIds.claudeCode,
        event: event,
        body: '{"session_id":"hook-$i"}',
      );
    }
  }

  group('nothing is capped by list position', () {
    for (final count in [100, 500]) {
      test(
        '$count hook-backed sessions are all covered in one cycle',
        () async {
          addHookedSessions(count);
          // A budget of one: even a registry that could afford exactly one disk
          // read must still observe every hook, because a hook costs nothing.
          final registry = build(probeBudget: 1);

          final cycle = await registry.cycle();

          expect(cycle.entries, hasLength(count));
          expect(registry.trackedCount, count);
          for (var i = 0; i < count; i++) {
            final report = registry.reportForKey(
              AgentSessionKey(AgentIds.claudeCode, 'hook-$i'),
            );
            expect(
              report?.status,
              AgentActivityStatus.working,
              reason: 'session $i was not observed',
            );
            expect(report?.source, AgentStatusSource.hook);
          }
          expect(registry.probes, 0, reason: 'a hook needs no disk read');
        },
      );
    }

    test('hook coverage does not depend on where a session sorts', () async {
      // The 60-cap bug in one assertion: the last session in the list is as
      // well observed as the first.
      addHookedSessions(120);
      final registry = build(probeBudget: 2);
      await registry.cycle();

      expect(
        registry
            .reportForKey(
              const AgentSessionKey(AgentIds.claudeCode, 'hook-119'),
            )
            ?.status,
        AgentActivityStatus.working,
      );
    });
  });

  group('the fallback probe budget', () {
    test('spends exactly the budget when more sessions want one', () async {
      addTranscriptSessions(100);
      final registry = build(probeBudget: 10);

      final cycle = await registry.cycle();

      expect(cycle.probed, 10);
      expect(source.calls, 10);
      expect(
        registry.entries.where((e) => e.lastProbedAt != null).length,
        10,
        reason: 'a budget is a budget',
      );
    });

    test('spends nothing extra when everyone fits', () async {
      addTranscriptSessions(6);
      final registry = build(probeBudget: 10);

      final cycle = await registry.cycle();

      expect(cycle.probed, 6);
      expect(source.calls, 6);
    });

    for (final (count, budget) in [(100, 10), (500, 24)]) {
      test(
        'the rotation reaches all $count sessions within ceil(n/$budget) cycles',
        () async {
          addTranscriptSessions(count);
          final registry = build(probeBudget: budget);
          final needed = (count / budget).ceil();

          for (var i = 0; i < needed; i++) {
            clock.now = clock.now.add(kStatusCycleInterval);
            await registry.cycle();
          }

          final unprobed = registry.entries
              .where((e) => e.lastProbedAt == null)
              .toList();
          expect(
            unprobed,
            isEmpty,
            reason: '${unprobed.length} of $count never got a turn',
          );
          for (final entry in registry.entries) {
            expect(entry.report.status, AgentActivityStatus.idle);
            expect(entry.report.source, AgentStatusSource.stateFile);
          }
        },
      );
    }

    test('a busy priority tier cannot starve the rotation', () async {
      // Thirty sessions on screen and a budget of twelve. Priority alone would
      // read those thirty forever and never reach session thirty-one — the
      // 60-cap bug in a different costume. A third of the budget is reserved.
      addTranscriptSessions(90);
      visible = {for (var i = 0; i < 30; i++) 'cli-$i'};
      final registry = build(probeBudget: 12);

      // ceil(60 / reserve=4) cycles is the guaranteed bound for the other 60.
      for (var i = 0; i < 15; i++) {
        clock.now = clock.now.add(kStatusCycleInterval);
        await registry.cycle();
      }

      final starved = registry.entries
          .where((e) => e.lastProbedAt == null)
          .map((e) => e.key.sessionId)
          .toList();
      expect(starved, isEmpty, reason: 'starved: $starved');
    });

    test(
      'probes run concurrently, capped, rather than one after another',
      () async {
        addTranscriptSessions(20);
        source.delay = const Duration(milliseconds: 2);
        final registry = build(probeBudget: 20, probeConcurrency: 4);

        await registry.cycle();

        expect(source.peakInFlight, 4, reason: 'the cap is the cap');
        expect(
          source.peakInFlight,
          greaterThan(1),
          reason: 'serial probing is what let one slow file blow the cycle',
        );
      },
    );

    test('an unchanged transcript costs a stat and no read', () async {
      addTranscriptSessions(4);
      final registry = build(probeBudget: 10);

      await registry.cycle();
      expect(source.reads, 4);

      await registry.cycle();
      expect(source.calls, 8, reason: 'still probed');
      expect(source.reads, 4, reason: 'but nothing moved, so nothing was read');
    });
  });

  group('the shape of the cost at a hundred sessions', () {
    test(
      'ten seconds of cycles is bounded by the budget, not the count',
      () async {
        // The measurement Loop 87 reports. Ten seconds at the default 1.2 s
        // cycle is eight passes.
        //
        // Before: one poller *per rendered badge* at 1.2 s, each calling the
        // status service, each reading its transcript from disk with no mtime
        // cache — 100 rows x 8 ticks = 800 tail reads in ten seconds (~83/s),
        // plus a full CLI-store scan per unresolved badge every 10 s (up to 100
        // scans, ~10/s), plus the 5-second watcher reading up to 60 more.
        addTranscriptSessions(100);
        final registry = build();

        for (var i = 0; i < 8; i++) {
          clock.now = clock.now.add(kStatusCycleInterval);
          await registry.cycle();
        }

        expect(registry.cycles, 8, reason: 'one pass for all 100, eight times');
        expect(
          registry.probes,
          8 * kStatusProbeBudget,
          reason: 'the budget is the ceiling: 24 a cycle, ~20 a second',
        );
        expect(
          registry.tailReads,
          100,
          reason: 'each transcript read once; unchanged files cost a stat',
        );
        expect(registry.transcriptScans, 0, reason: 'every path was known');
        // ...and every one of the hundred is covered, which is the half the old
        // 60-session watcher could not do at any price.
        expect(registry.entries.where((e) => e.lastProbedAt == null), isEmpty);
      },
    );
  });

  group('state survives a cycle that did not sample it', () {
    test('a session the rotation skipped keeps its last status', () async {
      addTranscriptSessions(3);
      final registry = build(probeBudget: 1);
      const first = AgentSessionKey(AgentIds.claudeCode, 'cli-0');

      await registry.cycle();
      expect(registry.reportForKey(first)?.status, AgentActivityStatus.idle);

      // Two cycles that spend their single probe on somebody else.
      clock.now = clock.now.add(kStatusCycleInterval);
      await registry.cycle();
      clock.now = clock.now.add(kStatusCycleInterval);
      await registry.cycle();

      expect(
        registry.reportForKey(first)?.status,
        AgentActivityStatus.idle,
        reason: 'not sampled is not the same as not known',
      );
      expect(registry.reportForKey(first)?.source, AgentStatusSource.stateFile);
    });

    test('a change is still seen when the rotation comes back round', () async {
      addTranscriptSessions(3);
      final registry = build(probeBudget: 1);
      const first = AgentSessionKey(AgentIds.claudeCode, 'cli-0');

      await registry.cycle();
      expect(registry.reportForKey(first)?.status, AgentActivityStatus.idle);

      // The agent starts a turn while cli-0 is out of the sampled set.
      source.records['store/cli-0.jsonl'] = {'type': 'user'};
      source.modified['store/cli-0.jsonl'] = testTime.add(
        const Duration(seconds: 1),
      );

      for (var i = 0; i < 3; i++) {
        clock.now = clock.now.add(kStatusCycleInterval);
        await registry.cycle();
      }

      expect(registry.reportForKey(first)?.status, AgentActivityStatus.working);
    });

    test('only leaving the watch set forgets a session', () async {
      addTranscriptSessions(2);
      final registry = build();
      const first = AgentSessionKey(AgentIds.claudeCode, 'cli-0');

      await registry.cycle();
      expect(registry.reportForKey(first), isNotNull);

      watched.removeAt(0);
      await registry.cycle();

      expect(registry.reportForKey(first), isNull);
      expect(registry.trackedCount, 1);
    });

    test('a cached transcript ages out of working on its own', () async {
      // The one time-dependent classification. The snapshot is not re-read, so
      // if staleness were baked in at read time this would stay `working`
      // forever.
      addTranscriptSessions(1);
      source.records['store/cli-0.jsonl'] = {'type': 'user'};
      final registry = build(probeBudget: 1);

      await registry.cycle();
      expect(
        registry
            .reportForKey(const AgentSessionKey(AgentIds.claudeCode, 'cli-0'))
            ?.status,
        AgentActivityStatus.working,
      );

      clock.now = testTime.add(const Duration(minutes: 10));
      await registry.cycle();

      expect(
        registry
            .reportForKey(const AgentSessionKey(AgentIds.claudeCode, 'cli-0'))
            ?.status,
        AgentActivityStatus.unknown,
      );
    });
  });

  group('transcript paths are resolved once, centrally', () {
    test('one scan answers for every session that needs a path', () async {
      var scans = 0;
      for (var i = 0; i < 50; i++) {
        source.records['found/cli-$i.jsonl'] = {'type': 'assistant'};
        watched.add(
          WatchedSession(
            key: AgentSessionKey(AgentIds.claudeCode, 'cli-$i'),
            label: 'Native $i',
            openId: 'row-$i',
            imported: false,
          ),
        );
      }
      final registry = build(
        probeBudget: 50,
        resolveTranscripts: () async {
          scans++;
          return {
            for (var i = 0; i < 50; i++)
              '${AgentIds.claudeCode}/cli-$i': 'found/cli-$i.jsonl',
          };
        },
      );

      final cycle = await registry.cycle();

      expect(scans, 1, reason: 'fifty sessions, one scan');
      expect(cycle.scans, 1);
      expect(cycle.probed, 50, reason: 'and they are usable the same cycle');
      for (final entry in registry.entries) {
        expect(entry.report.status, AgentActivityStatus.idle);
      }
    });

    test('a resolved path is never looked up again', () async {
      var scans = 0;
      addHookedSessions(1);
      watched.add(
        const WatchedSession(
          key: AgentSessionKey(AgentIds.claudeCode, 'cli-0'),
          label: 'Native',
          openId: 'row-0',
          imported: false,
        ),
      );
      source.records['found/cli-0.jsonl'] = {'type': 'assistant'};
      final registry = build(
        resolveTranscripts: () async {
          scans++;
          return {'${AgentIds.claudeCode}/cli-0': 'found/cli-0.jsonl'};
        },
      );

      await registry.cycle();
      clock.now = clock.now.add(const Duration(minutes: 5));
      await registry.cycle();
      await registry.cycle();

      expect(scans, 1);
      expect(registry.transcriptScans, 1);
    });

    test(
      'an unresolved session rescans on its own slow interval, not per tick',
      () async {
        var scans = 0;
        watched.add(
          const WatchedSession(
            key: AgentSessionKey(AgentIds.claudeCode, 'cli-missing'),
            label: 'Native',
            openId: 'row-0',
            imported: false,
          ),
        );
        final registry = build(
          resolveTranscripts: () async {
            scans++;
            return const {};
          },
        );

        for (var i = 0; i < 5; i++) {
          clock.now = clock.now.add(kStatusCycleInterval);
          await registry.cycle();
        }
        expect(scans, 1, reason: 'five cycles inside one search interval');

        clock.now = clock.now.add(kTranscriptSearchInterval);
        await registry.cycle();
        expect(scans, 2);
      },
    );

    test('a session the CLI never named asks for no scan at all', () async {
      var scans = 0;
      // A native session launched seconds ago: its key *is* its workspace row
      // id, so no transcript can ever match it and asking is pure waste.
      watched.add(
        const WatchedSession(
          key: AgentSessionKey(AgentIds.claudeCode, 'row-0'),
          label: 'Just launched',
          openId: 'row-0',
          imported: false,
        ),
      );
      final registry = build(
        resolveTranscripts: () async {
          scans++;
          return const {};
        },
      );

      await registry.cycle();

      expect(scans, 0);
    });
  });

  group('coverage is reported, not merely guaranteed', () {
    // The registry already guarantees coverage by construction: membership is
    // uncapped and the rotation reserves a share priority traffic cannot take.
    // The 60-session cap survived to production because nobody could *tell*,
    // and a guarantee nobody can observe is the same shape of bug.

    test('a cycle says how much of the watch set it reached', () async {
      addTranscriptSessions(100);
      addHookedSessions(10);
      final registry = build(probeBudget: 24);
      addTearDown(registry.dispose);

      final coverage = (await registry.cycle()).coverage;

      expect(coverage.tracked, 110, reason: 'nothing is capped by position');
      expect(
        coverage.hookAnswered,
        10,
        reason: 'the primary path\'s actual share of the workspace',
      );
      expect(coverage.probeCandidates, 100);
      expect(coverage.probed, 24);
      expect(coverage.neverProbed, 76, reason: 'queued, not lost');
      expect(coverage.probeFailures, 0);
      expect(registry.coverage, coverage);
    });

    test('coverage is watchable, and an unchanged cycle is silent', () async {
      // The number reaches the log and (now) a Diagnostics row. A row can only
      // show it if the registry says when it moved, and must not repaint 50
      // times a minute when it did not.
      final registry = build();
      addTearDown(registry.dispose);
      final seen = <SessionStatusCoverage?>[];
      final sub = registry.coverageReports.listen(seen.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);

      expect(seen, [null], reason: 'nothing has been measured yet');

      await registry.cycle();
      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(2));
      expect(seen.last?.tracked, 0);

      await registry.cycle();
      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(2), reason: 'the measurement did not move');

      addHookedSessions(3);
      await registry.cycle();
      await Future<void>.delayed(Duration.zero);
      expect(seen.last?.tracked, 3);
    });

    test('a session queued for a probe is not one we stopped watching', () {
      // The distinction the whole registry turns on, stated as a number a
      // human can read: 76 sessions with no transcript read yet is a healthy
      // rotation mid-turn; 76 sessions *missing* would be the old bug.
      const behind = SessionStatusCoverage(
        tracked: 110,
        hookAnswered: 10,
        probeCandidates: 100,
        probed: 24,
        neverProbed: 76,
        probeFailures: 0,
        rotationPeriod: Duration(seconds: 16),
      );
      expect(behind.isBehind, isFalse);
      expect(behind.toString(), contains('110 watched'));
    });

    test(
      'the rotation reaches everyone inside the period it reports',
      () async {
        // The reported period has to be a promise, not a decoration.
        addTranscriptSessions(500);
        final registry = build(probeBudget: 24);
        addTearDown(registry.dispose);
        final period = (await registry.cycle()).coverage.rotationPeriod!;
        final cycles =
            period.inMilliseconds ~/ kStatusCycleInterval.inMilliseconds;

        for (var i = 1; i < cycles; i++) {
          clock.now = clock.now.add(kStatusCycleInterval);
          await registry.cycle();
        }

        expect(
          registry.entries.where((e) => e.lastProbedAt == null),
          isEmpty,
          reason: 'the reported rotation period must bound the real one',
        );
      },
    );

    test('a rotation that cannot keep up says so, once', () async {
      final records = <LogRecord>[];
      AppLogger.initialize(level: Level.ALL, onRecord: records.add);
      // Restored to a sink that swallows rather than to the default one, which
      // echoes to the console: there is no way to read back the handler this
      // replaced, and the rest of this file cycles a great many registries.
      addTearDown(() => AppLogger.initialize(onRecord: (_) {}));

      // Far past the audit's top tier, with a budget that cannot walk it
      // inside the ceiling.
      addTranscriptSessions(2000);
      final registry = build(probeBudget: 24);
      addTearDown(registry.dispose);

      for (var i = 0; i < 5; i++) {
        clock.now = clock.now.add(kStatusCycleInterval);
        await registry.cycle();
      }

      final warnings = records.where((r) => r.level >= Level.WARNING).toList();
      expect(
        warnings,
        hasLength(1),
        reason: 'edge-triggered: a line per 1.2 s cycle would bury the log',
      );
      expect(warnings.single.message, contains('2000'));
      expect(
        records.where((r) => r.message.contains('watching')),
        hasLength(1),
        reason: 'the watch set size is reported when it changes, not per cycle',
      );

      // And it says so again when it recovers, so a log that once warned is
      // not evidence that it still is.
      watched.removeRange(50, watched.length);
      clock.now = clock.now.add(kStatusCycleInterval);
      await registry.cycle();
      expect(registry.coverage?.isBehind, isFalse);
      expect(
        records.where((r) => r.message.contains('keeping up')),
        hasLength(1),
      );
    });
  });

  group('the cheap sources answer for everyone', () {
    test("a live pane's screen is read without any disk work", () async {
      watched.add(
        const WatchedSession(
          key: AgentSessionKey(AgentIds.claudeCode, 'row-0'),
          label: 'Native',
          openId: 'row-0',
          imported: false,
        ),
      );
      final registry = build(readTail: (_) => const ['  esc to interrupt  ']);

      await registry.cycle();

      final report = registry.reportForOpenId('row-0');
      expect(report?.status, AgentActivityStatus.working);
      expect(report?.source, AgentStatusSource.terminalGrid);
      expect(source.calls, 0);
    });

    // A cycle can sit in its disk work for seconds — a launch's first store
    // scan and sync. A session that joins the watch set meanwhile, and what
    // memory already says about it, must not wait for that to finish.
    test('a cycle still on its disk work does not hold back what memory '
        'says', () async {
      final passenger = Completer<void>();
      addTearDown(passenger.complete);
      final registry = build(
        readTail: (_) => const ['  esc to interrupt  '],
        onCycle: (_) => passenger.future,
      );
      unawaited(registry.cycle());
      await pumpEventQueue();

      watched.add(
        const WatchedSession(
          key: AgentSessionKey(AgentIds.claudeCode, 'row-late'),
          label: 'Late',
          openId: 'row-late',
          imported: false,
        ),
      );
      final heard = registry
          .reportsFor('row-late')
          .firstWhere((r) => r.status == AgentActivityStatus.working);
      // The timer's next tick joins the pass still running.
      unawaited(registry.cycle());

      final report = await heard.timeout(const Duration(seconds: 1));
      expect(report.source, AgentStatusSource.terminalGrid);
      expect(registry.cycles, 1, reason: 'no second disk pass was started');
    });

    test('a screen showing an approval outranks the transcript', () async {
      addTranscriptSessions(1);
      final registry = build(readTail: (_) => const ['  Enter to confirm  ']);

      await registry.cycle();

      expect(
        registry.reportForOpenId('row-cli-0')?.status,
        AgentActivityStatus.awaitingApproval,
      );
      expect(source.calls, 0, reason: 'an escalating grid skips the disk');
    });
  });

  group('reading a status', () {
    test('a subscriber is answered immediately, even for a stranger', () async {
      final registry = build();

      final first = await registry.reportsFor('nobody').first;

      expect(first.status, AgentActivityStatus.unknown);
      expect(first.source, AgentStatusSource.none);
    });

    test('a subscriber hears changes but not reconfirmations', () async {
      addTranscriptSessions(1);
      final registry = build();
      final seen = <AgentActivityStatus>[];
      final sub = registry
          .reportsFor('row-cli-0')
          .listen((report) => seen.add(report.status));
      addTearDown(sub.cancel);
      await Future<void>.value();

      await registry.cycle();
      await registry.cycle();
      await registry.cycle();
      await pumpMicrotasks();

      expect(seen, [AgentActivityStatus.unknown, AgentActivityStatus.idle]);

      source.records['store/cli-0.jsonl'] = {'type': 'user'};
      source.modified['store/cli-0.jsonl'] = testTime.add(
        const Duration(seconds: 1),
      );
      await registry.cycle();
      await pumpMicrotasks();

      expect(seen.last, AgentActivityStatus.working);
    });
  });

  group('the cycle carries its passengers', () {
    test(
      'a passenger runs every cycle but may scan the stores rarely',
      () async {
        final scanOffers = <bool>[];
        final registry = build(
          onCycle: (mayScanStores) async => scanOffers.add(mayScanStores),
        );

        for (var i = 0; i < 5; i++) {
          await registry.cycle();
          clock.now = clock.now.add(kStatusCycleInterval);
        }

        // Every cycle, so a free in-memory observation is never skipped …
        expect(scanOffers, hasLength(5));
        // … and one store slot, because five cycles is six seconds and the slot
        // is offered once every ten.
        expect(scanOffers.where((offered) => offered), hasLength(1));
        expect(registry.storeSlots, 1);
      },
    );

    test('the store slot reopens once its interval has passed', () async {
      final scanOffers = <bool>[];
      final registry = build(
        onCycle: (mayScanStores) async => scanOffers.add(mayScanStores),
      );

      await registry.cycle();
      clock.now = clock.now.add(kTranscriptSearchInterval);
      await registry.cycle();

      expect(scanOffers, [true, true]);
    });

    test('a passenger that throws does not take the cycle down', () async {
      addTranscriptSessions(1);
      final registry = build(
        onCycle: (_) async => throw StateError('adoption exploded'),
      );

      final cycle = await registry.cycle();

      expect(cycle.entries, hasLength(1));
      expect(
        registry.reportForOpenId('row-cli-0')?.status,
        AgentActivityStatus.idle,
      );
    });
  });

  group('a hook does not wait for a cycle', () {
    late SessionStatusRegistry registry;

    /// One callback for `hook-$i`, exactly as `/agent-hook` delivers it.
    void hookArrives(int i, String event) {
      receiver.handle(
        agentId: AgentIds.claudeCode,
        event: event,
        body: '{"session_id":"hook-$i"}',
      );
      registry.hookReported(AgentSessionKey(AgentIds.claudeCode, 'hook-$i'));
    }

    test('it is applied in place, with no cycle and no disk', () async {
      addHookedSessions(1);
      registry = build();
      await registry.cycle();
      final cycles = registry.cycles;
      source.calls = 0;

      hookArrives(0, 'Notification');

      expect(
        registry
            .reportForKey(const AgentSessionKey(AgentIds.claudeCode, 'hook-0'))
            ?.status,
        AgentActivityStatus.awaitingApproval,
      );
      expect(registry.cycles, cycles, reason: 'no cycle was needed');
      expect(registry.hookFastUpdates, 1);
      expect(source.calls, 0, reason: 'and no probe');
    });

    test('saying the same thing again publishes nothing', () async {
      addHookedSessions(1);
      registry = build();
      await registry.cycle();

      final changes = <SessionStatusEntry>[];
      final subscription = registry.hookChanges.listen(changes.add);
      addTearDown(subscription.cancel);

      hookArrives(0, 'Notification');
      hookArrives(0, 'Notification');
      hookArrives(0, 'Notification');
      await pumpMicrotasks();

      expect(registry.hookReports, 3);
      expect(
        changes,
        hasLength(1),
        reason: 'a chatty agent costs a lookup each and wakes nobody',
      );
      expect(registry.hookFastUpdates, 1);
    });

    test('a badge hears it without a cycle', () async {
      addHookedSessions(1);
      registry = build();
      await registry.cycle();

      final seen = <AgentActivityStatus>[];
      final subscription = registry
          .reportsFor('row-hook-0')
          .listen((report) => seen.add(report.status));
      addTearDown(subscription.cancel);
      await pumpMicrotasks();
      expect(seen, [AgentActivityStatus.working]);

      hookArrives(0, 'Notification');
      await pumpMicrotasks();

      expect(seen, [
        AgentActivityStatus.working,
        AgentActivityStatus.awaitingApproval,
      ]);
    });

    test(
      'a stranger forces one cycle per floor, not one per callback',
      () async {
        registry = build();
        const stranger = AgentSessionKey(AgentIds.claudeCode, 'stranger');

        for (var i = 0; i < 20; i++) {
          registry.hookReported(stranger);
        }
        await registry.cycle();
        expect(registry.hookReports, 20);
        expect(registry.hookCycles, 1);

        clock.now = clock.now.add(kHookCycleFloor);
        registry.hookReported(stranger);
        await registry.cycle();
        expect(registry.hookCycles, 2);
      },
    );

    for (final count in [100, 500]) {
      test('$count sessions, one hook each, cost no cycle at all', () async {
        addHookedSessions(count);
        registry = build(
          resolveTranscripts: () async {
            fail('a hook must not be able to start a store scan');
          },
        );
        await registry.cycle();
        final cycles = registry.cycles;
        source.calls = 0;

        final changes = <SessionStatusEntry>[];
        final subscription = registry.hookChanges.listen(changes.add);
        addTearDown(subscription.cancel);

        for (var i = 0; i < count; i++) {
          hookArrives(i, 'Notification');
        }
        await pumpMicrotasks();

        expect(changes, hasLength(count), reason: 'every one of them landed');
        expect(registry.cycles, cycles);
        expect(registry.probes, 0);
        expect(registry.transcriptScans, 0);
        expect(source.calls, 0);
      });
    }
  });
}

/// Lets already-queued microtasks run, so a broadcast subscriber has been
/// delivered everything published so far.
Future<void> pumpMicrotasks() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.value();
  }
  // A broadcast controller delivers each event in its own microtask, so a burst
  // of a hundred needs the whole queue drained, not eight turns of it. A
  // zero-duration timer fires only once nothing is left in it.
  await Future<void>.delayed(Duration.zero);
}
