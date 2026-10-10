import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/explorer/application/agent_state_providers.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/explorer/application/workspace_session_entry.dart';
import 'package:karmashala/src/features/overview/application/overview_board.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';
import 'package:karmashala/src/features/overview/application/overview_today.dart';
import 'package:karmashala/src/features/overview/presentation/overview_counters.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/fakes.dart';

/// **Today**: what needs you, what finished since the last look, what is
/// stuck and what runs — each part a filter, zeros left out.
void main() {
  final now = DateTime.utc(2026, 10, 9, 15);
  final startOfToday = DateTime.utc(2026, 10, 9);

  WorkspaceSessionEntry entry(String id, {Duration age = Duration.zero}) =>
      WorkspaceSessionEntry(
        id: id,
        title: 'T $id',
        createdAt: now.subtract(age),
        lastActiveAt: now.subtract(age),
        directory: EnvironmentPath(environmentId: 'windows', path: '/src/$id'),
        native: Session(
          id: id,
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: 'T $id',
          useWorktree: false,
          status: SessionStatus.running,
          createdAt: now.subtract(age),
        ),
      );

  OverviewBoard board(
    Map<AgentState, List<WorkspaceSessionEntry>> by, {
    Set<String> drawnElsewhere = const {},
  }) => buildOverviewBoard(
    [
      for (final state in AgentState.values)
        AgentStateGroup(state, by[state] ?? const []),
    ],
    facts: OverviewFacts(
      projectOf: (_) => 'p1',
      machineOf: (e) => e.directory?.environmentId,
      agentOf: (_) => 'claude-code',
      projects: const [OverviewLaneKey('p1', 'Alpha')],
      machines: const [OverviewLaneKey('windows', 'Windows')],
    ),
    filter: const OverviewFilter(),
    groupBy: OverviewGroupBy.project,
    startOfToday: startOfToday,
    memo: BoardOrderMemo(),
    drawnElsewhere: drawnElsewhere,
  );

  OverviewStrip strip(OverviewBoard b) => summarizeStrip(
    b,
    now: now,
    waitingSince: (_) => now.subtract(const Duration(minutes: 7)),
    cost: (_) => null,
  );

  final full = board({
    AgentState.needsYou: [entry('n')],
    AgentState.failed: [entry('f')],
    AgentState.working: [entry('w'), entry('w2')],
    AgentState.quiet: [entry('q')],
    AgentState.ready: [entry('r', age: const Duration(minutes: 5))],
    AgentState.ended: [entry('e', age: const Duration(hours: 2))],
  });

  group('the model', () {
    test('counts each part; finished is what ended since the last look', () {
      final today = overviewTodayOf(
        full,
        strip: strip(full),
        capacity: CapacitySnapshot.empty,
        lookedAt: now.subtract(const Duration(hours: 1)),
        startOfToday: startOfToday,
        firstWaitingId: 'n',
      );
      expect(today.needsYou, 1);
      expect(today.oldestWait, const Duration(minutes: 7));
      expect(today.firstWaitingId, 'n');
      // The one ended two hours ago was before the look.
      expect(today.finished, ['r']);
      expect(today.stuck, 2);
      expect(today.stuckDetail, '1 quiet · 1 failed');
      expect(today.running, 3);
      expect(today.runningLabel, '3 running');
    });

    test('never looked: the day so far counts', () {
      final today = overviewTodayOf(
        full,
        strip: strip(full),
        capacity: CapacitySnapshot.empty,
        lookedAt: null,
        startOfToday: startOfToday,
      );
      expect(today.finished, unorderedEquals(['r', 'e']));
    });

    test('with a limit, Running reads the slots and the line', () {
      final today = overviewTodayOf(
        full,
        strip: strip(full),
        capacity: CapacitySnapshot(
          limits: const LaunchLimits(global: 4),
          running: 3,
          waiters: [
            LaunchWaiter(
              ticketId: 't1',
              label: 'Fix the cart',
              priority: LaunchPriority.interactive,
              place: 1,
              reason: 'Waiting for a slot',
              enqueuedAt: now,
            ),
          ],
        ),
        lookedAt: now,
        startOfToday: startOfToday,
        gatesWaiting: 1,
      );
      expect(today.runningLabel, '3/4 running · 1 waiting');
      // A launch waiting for a slot is stuck; a gate needs you.
      expect(today.stuck, 3);
      expect(today.needsYou, 2);
    });

    test('a pipeline stage\'s session is drawn in its run, not loose', () {
      final b = board(
        {
          AgentState.working: [entry('w'), entry('stage')],
        },
        drawnElsewhere: {'stage'},
      );
      expect(b.states.keys, ['w']);
    });

    test('each part filters to its own and knows when it is chosen', () {
      for (final part in OverviewTodayPart.values) {
        final own = part.filter;
        final filter = OverviewFilter(columns: own.columns, states: own.states);
        for (final other in OverviewTodayPart.values) {
          expect(other.selectedIn(filter), other == part, reason: '$part');
        }
      }
      final stuck = OverviewTodayPart.stuck.filter;
      final filter = OverviewFilter(
        columns: stuck.columns,
        states: stuck.states,
      );
      expect(filter.shows(AgentState.failed), isTrue);
      expect(filter.shows(AgentState.quiet), isTrue);
      expect(filter.shows(AgentState.needsYou), isFalse);
      expect(filter.shows(AgentState.working), isFalse);
    });
  });

  group('the strip', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ks-today');
    });
    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        // Windows may still hold the file; the OS sweeps temp.
      }
    });

    Future<ProviderContainer> pump(
      WidgetTester tester,
      OverviewToday today, {
      Size size = const Size(1440, 900),
      double scale = 1,
      bool compact = false,
    }) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final container = ProviderContainer(
        overrides: [
          overviewTodayProvider.overrideWithValue(today),
          agentsHiddenWorkingCountProvider.overrideWithValue(0),
          overviewPrefsDirectoryProvider.overrideWithValue(() async => dir),
          clockProvider.overrideWithValue(FixedClock(now)),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: UiDensity.wrap(context, child!),
            ),
            home: Scaffold(
              body: compact
                  ? SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: OverviewTodayStrip(compact: true),
                    )
                  : const OverviewTodayStrip(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    Finder part(OverviewTodayPart part) =>
        find.byKey(ValueKey('overview-today:${part.name}'));

    testWidgets('zeros are left out; nothing at all is All clear', (
      tester,
    ) async {
      await pump(
        tester,
        const OverviewToday(needsYou: 2, running: 3, limit: 4, slotWaiting: 1),
      );
      expect(part(OverviewTodayPart.needsYou), findsOneWidget);
      expect(part(OverviewTodayPart.finished), findsNothing);
      expect(part(OverviewTodayPart.stuck), findsOneWidget);
      expect(find.text('3/4 running · 1 waiting'), findsOneWidget);

      await pump(tester, const OverviewToday());
      expect(find.byKey(const ValueKey('overview-all-clear')), findsOneWidget);
    });

    testWidgets('each part filters the Board, and taps again to clear', (
      tester,
    ) async {
      final c = await pump(
        tester,
        const OverviewToday(
          needsYou: 1,
          finished: ['r'],
          failed: 1,
          running: 2,
        ),
      );
      for (final p in OverviewTodayPart.values) {
        await tester.tap(part(p));
        await tester.pumpAndSettle();
        final filter = c.read(overviewPrefsProvider).filter;
        expect(p.selectedIn(filter), isTrue, reason: '$p');
        await tester.tap(part(p));
        await tester.pumpAndSettle();
        expect(c.read(overviewPrefsProvider).filter.allStates, isTrue);
      }
    });

    testWidgets('"Seen" moves the since-you-looked marker to now', (
      tester,
    ) async {
      final c = await pump(tester, const OverviewToday(finished: ['r', 'e']));
      expect(find.text('2'), findsOneWidget);
      expect(find.text('finished'), findsOneWidget);
      expect(c.read(overviewLookedAtProvider), isNull);
      await tester.tap(find.byKey(const ValueKey('overview-today-seen')));
      await tester.pumpAndSettle();
      expect(c.read(overviewLookedAtProvider), now);
    });

    test('the marker is kept on this device', () async {
      final c = ProviderContainer(
        overrides: [
          overviewPrefsDirectoryProvider.overrideWithValue(() async => dir),
        ],
      );
      addTearDown(c.dispose);
      c.read(overviewLookedAtProvider.notifier).markLooked(now);
      final file = File('${dir.path}/overview_looked.json');
      for (var i = 0; i < 100 && !file.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final fresh = ProviderContainer(
        overrides: [
          overviewPrefsDirectoryProvider.overrideWithValue(() async => dir),
        ],
      );
      addTearDown(fresh.dispose);
      var kept = fresh.read(overviewLookedAtProvider);
      for (var i = 0; i < 100 && kept == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        kept = fresh.read(overviewLookedAtProvider);
      }
      expect(kept, now);
    });

    const busy = OverviewToday(
      needsYou: 3,
      oldestWait: Duration(minutes: 42),
      finished: ['a', 'b'],
      failed: 1,
      quiet: 1,
      slotWaiting: 1,
      running: 3,
      limit: 4,
    );
    for (final (size, compact) in [
      (const Size(360, 800), true),
      (const Size(412, 800), true),
      (const Size(1440, 900), false),
    ]) {
      for (final scale in [1.0, 1.6]) {
        testWidgets('${size.width}px at ${scale}x: every part fits', (
          tester,
        ) async {
          await pump(tester, busy, size: size, scale: scale, compact: compact);
          expect(tester.takeException(), isNull);
          for (final p in OverviewTodayPart.values) {
            expect(part(p), findsOneWidget);
          }
        });
      }
    }
  });
}
