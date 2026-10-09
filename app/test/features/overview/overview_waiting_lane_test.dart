import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/overview/presentation/overview_waiting_lane.dart';
import 'package:karmashala/src/features/sessions/application/capacity_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/slot_wait_notice.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

class _Actions implements CapacityActions {
  final startedAnyway = <String>[];
  final cancelled = <String>[];

  @override
  Future<void> startAnyway(String ticketId) async =>
      startedAnyway.add(ticketId);

  @override
  Future<void> cancel(String ticketId) async => cancelled.add(ticketId);
}

/// Waiting for a concurrency slot: the dashboard's lane, a session's notice
/// with Start anyway and Cancel, and the summary.
void main() {
  final person = LaunchWaiter(
    ticketId: 't1',
    label: 'Fix the cart',
    sessionId: 's1',
    priority: LaunchPriority.interactive,
    place: 1,
    reason: 'Waiting for a slot: 2 of 2 on WSL · archlinux are busy (X, Y)',
    enqueuedAt: DateTime.utc(2026, 10, 9, 12),
    personStarted: true,
  );
  final background = LaunchWaiter(
    ticketId: 't2',
    label: 'Nightly triage',
    sessionId: 's2',
    priority: LaunchPriority.background,
    place: 2,
    reason: 'Waiting: new background work is paused',
    enqueuedAt: DateTime.utc(2026, 10, 9, 12, 1),
  );
  final snapshot = CapacitySnapshot(
    limits: const LaunchLimits(global: 4, pauseBackground: true),
    running: 3,
    waiters: [person, background],
  );

  Future<_Actions> pump(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(1440, 900),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final actions = _Actions();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          capacityNowProvider.overrideWithValue(snapshot),
          capacityActionsProvider.overrideWithValue(actions),
        ],
        child: MaterialApp(
          builder: (context, c) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: c!,
          ),
          home: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return actions;
  }

  testWidgets('the lane lists each wait with its reason and place', (
    tester,
  ) async {
    await pump(tester, const OverviewWaitingLane());
    expect(find.text('WAITING FOR A SLOT · 2'), findsOneWidget);
    expect(find.text('Fix the cart'), findsOneWidget);
    expect(
      find.text(
        'Waiting for a slot: 2 of 2 on WSL · archlinux are busy (X, Y). '
        '1st in line; it starts by itself.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('2nd in line'), findsOneWidget);
    // Start anyway is a person's own start's; Cancel is everyone's.
    expect(
      find.byKey(const ValueKey('slot-wait-start-anyway:t1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('slot-wait-start-anyway:t2')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('slot-wait-cancel:t2')), findsOneWidget);
  });

  testWidgets('Start anyway asks first, then starts', (tester) async {
    final actions = await pump(tester, const SlotWaitNotice(sessionId: 's1'));
    await tester.tap(find.byKey(const ValueKey('slot-wait-start-anyway:t1')));
    await tester.pumpAndSettle();
    expect(find.text('Start over the limit?'), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(actions.startedAnyway, isEmpty);

    await tester.tap(find.byKey(const ValueKey('slot-wait-start-anyway:t1')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Start anyway'));
    await tester.pumpAndSettle();
    expect(actions.startedAnyway, ['t1']);
  });

  testWidgets('Cancel takes it out of line', (tester) async {
    final actions = await pump(tester, const SlotWaitNotice(sessionId: 's1'));
    await tester.tap(find.byKey(const ValueKey('slot-wait-cancel:t1')));
    await tester.pump();
    expect(actions.cancelled, ['t1']);
  });

  testWidgets('a session that is not waiting shows nothing', (tester) async {
    await pump(tester, const SlotWaitNotice(sessionId: 'other'));
    expect(find.byKey(const ValueKey('slot-wait:other')), findsNothing);
    expect(find.text('Start anyway'), findsNothing);
  });

  for (final (name, size, scale) in [
    ('360 px at text scale 1.6', const Size(360, 800), 1.6),
    ('desktop', const Size(1440, 900), 1.0),
  ]) {
    testWidgets('lane and notice fit: $name', (tester) async {
      await pump(
        tester,
        const Column(
          children: [
            OverviewWaitingLane(),
            SlotWaitNotice(sessionId: 's1'),
          ],
        ),
        size: size,
        textScale: scale,
      );
      expect(tester.takeException(), isNull);
    });
  }

  test('the summary', () {
    expect(capacitySummary(CapacitySnapshot.empty), isNull);
    expect(
      capacitySummary(snapshot),
      '3/4 running · 2 waiting · background paused',
    );
    expect(
      capacitySummary(
        const CapacitySnapshot(
          limits: LaunchLimits(machines: {'windows': 2}),
          running: 1,
        ),
      ),
      '1 running',
    );
  });

  test('places read as ordinals', () {
    expect([1, 2, 3, 4, 11, 12, 13, 21, 22].map(ordinal), [
      '1st',
      '2nd',
      '3rd',
      '4th',
      '11th',
      '12th',
      '13th',
      '21st',
      '22nd',
    ]);
  });
}
