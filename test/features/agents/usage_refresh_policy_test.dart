import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_usage_providers.dart';
import 'package:karmashala/src/features/agents/application/usage_refresh_policy.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/usage.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/agents/presentation/usage_chip.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import 'usage_fixtures.dart';

/// **When the quota is read again, and — far more importantly — when it is
/// not.**
///
/// One timer per *account*, cancelled outright on blur, armed at the moment the
/// reading itself says another request could learn something. The counted unit
/// is a fetch: every entry in `FakeAgentUsageService.calls` is one request that
/// would have gone to the vendor endpoint.
///
/// Two properties this file exists to hold:
///
/// * **the schedule comes off the payload.** A `five_hour` window has a hundred
///   points in it, so a point takes three minutes to spend and a request inside
///   three minutes cannot learn one. Idle, the wait doubles to
///   [kUsageIdleCeiling]. Measured below: an idle hour costs **6** requests
///   where the old fixed minute cost **60**, and nothing that fires in between
///   can exceed the floor, because the floor is enforced in the service.
/// * **the reading is per account, the display is per pane.** A hundred panes
///   on one account cost one request and hold one timer between them.
void main() {
  late AppDatabase db;
  late FakeAgentUsageService service;
  late MovableClock clock;

  /// The key both the throttle and the policy file this workspace's quota
  /// under: `claudeCode@windows`.
  final claudeAccount = usageAccountKey(agentInstallation());

  setUp(() {
    clock = MovableClock(testTime);
    // The service's own clock, so the age of a reading moves with the test's.
    // A fixed clock would make every reading eternally fresh and no schedule
    // here would ever be exercised.
    service = FakeAgentUsageService(clock: clock);
  });
  tearDown(() => db.close());

  /// Puts [sessions] chips on screen, one per session row, all on the one
  /// installation `seedUsageDatabase` creates unless [withOtherAgent] adds a
  /// second.
  Future<ProviderContainer> pumpChip(
    WidgetTester tester, {
    int sessions = 1,
    bool withOtherAgent = false,
  }) async {
    db = seedUsageDatabase();
    final dao = SessionDao(db);
    for (var i = 2; i <= sessions; i++) {
      dao.insert(session(id: 's$i'));
    }
    if (withOtherAgent) {
      // An agent with **no usage endpoint at all**. This was `antigravity`
      // until it grew one; a real agent that later gains a feature stops being
      // a stand-in for lacking it, and the test then asserts the opposite of
      // what it reads as.
      AgentInstallationDao(
        db,
      ).insert(agentInstallation(id: 'a2', agentId: 'unknownAgent'));
      dao.insert(session(id: 'other', agentInstallationId: 'a2'));
    }
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(clock),
        agentUsageServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(container.dispose);
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            // Scrolling, not for the scrolling: a hundred chips in a bare
            // `Column` overflow an 800x600 test window, and a `Column` inside a
            // scroll view still builds every one of them — which is the point
            // of asking for a hundred.
            body: SingleChildScrollView(
              child: Column(
                children: [
                  for (var i = 1; i <= sessions; i++)
                    UsageChip(sessionId: 's$i'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return container;
  }

  UsageRefreshController policyOf(ProviderContainer container) =>
      container.read(usageRefreshProvider(claudeAccount).notifier);

  void setFocus(ProviderContainer container, {required bool focused}) =>
      container.read(windowFocusedProvider.notifier).set(focused);

  void publish(ProviderContainer container, SessionChange change) =>
      container.read(sessionsRevisionProvider.notifier).changed(change);

  /// Moves the wall clock and the test clock together.
  ///
  /// Both, or the schedule is measured against a clock that never moves: the
  /// timer fires off `tester.pump`, and how old the reading is by then comes
  /// from [clock]. Advanced first, so the callbacks the pump runs read the time
  /// they are supposed to be running at.
  Future<void> elapse(WidgetTester tester, Duration by) async {
    clock.now = clock.now.add(by);
    await tester.pump(by);
    await tester.pump();
  }

  /// Leaves no pending timer behind, which `testWidgets` treats as a failure.
  Future<void> quiesce(WidgetTester tester, ProviderContainer container) async {
    setFocus(container, focused: false);
    await tester.pump();
  }

  testWidgets('reads once on mount, then when the payload says a point '
      'could have moved', (tester) async {
    final container = await pumpChip(tester);
    expect(service.calls.length, 1, reason: 'the chip fetches when it appears');
    expect(policyOf(container).isPolling, isTrue);
    expect(
      policyOf(container).delay,
      usageFixtureFloor,
      reason: 'three minutes, read off the five-hour window the reply named',
    );

    // The tick armed before that first reading landed could only use the
    // floor, so one lands at a minute. It costs an invalidate and no request.
    await elapse(tester, kUsageMinInterval);
    expect(
      service.calls.length,
      1,
      reason: 'a minute in, one point of a five-hour quota cannot be spent',
    );

    await elapse(tester, const Duration(minutes: 2));
    expect(service.calls.length, 2, reason: 'three minutes in, it asks');
    await quiesce(tester, container);
  });

  testWidgets('an idle hour costs six requests, where a fixed minute cost '
      'sixty', (tester) async {
    // The measurement behind the change. The fake answers with the same
    // percentages every time, which is what an account nobody is spending
    // looks like: the wait doubles 3m → 6m → 12m → 15m and holds there.
    final container = await pumpChip(tester);
    for (var minute = 0; minute < 60; minute++) {
      await elapse(tester, const Duration(minutes: 1));
    }
    expect(
      service.calls.length,
      6,
      reason: 'requests at 0, 3, 9, 21, 36 and 51 minutes',
    );

    // And the second hour is cheaper still, because the ladder has reached
    // its ceiling: four requests, one every fifteen minutes.
    for (var minute = 0; minute < 60; minute++) {
      await elapse(tester, const Duration(minutes: 1));
    }
    expect(
      service.calls.length,
      10,
      reason: 'a quarter of an hour apart, which is where the ladder stops',
    );
    expect(
      policyOf(container).delay,
      lessThanOrEqualTo(kUsageIdleCeiling),
      reason: 'the ladder stops here, so a reading stays worth looking at',
    );
    await quiesce(tester, container);
  });

  testWidgets('blur cancels the timer outright, and nothing is read while '
      'the owner is away', (tester) async {
    final container = await pumpChip(tester);
    final builds = UsageChip.debugBuildCount;

    setFocus(container, focused: false);
    await tester.pump();
    expect(
      policyOf(container).isPolling,
      isFalse,
      reason: 'the timer is cancelled, not left running and idle',
    );

    await elapse(tester, const Duration(hours: 1));
    expect(service.calls.length, 1, reason: 'an hour away, no requests');
    expect(
      UsageChip.debugBuildCount,
      builds,
      reason: 'a blurred chip does no work at all',
    );
    await quiesce(tester, container);
  });

  testWidgets('regaining focus after a long absence reads once and resumes', (
    tester,
  ) async {
    final container = await pumpChip(tester);
    setFocus(container, focused: false);
    await tester.pump();

    clock.now = clock.now.add(const Duration(hours: 8));
    setFocus(container, focused: true);
    await tester.pump();

    expect(service.calls.length, 2, reason: 'an overnight blur is stale');
    expect(policyOf(container).isPolling, isTrue);
    await quiesce(tester, container);
  });

  testWidgets('a flurry of focus changes inside the floor costs nothing', (
    tester,
  ) async {
    final container = await pumpChip(tester);

    // What a tiling window manager produces.
    for (var i = 0; i < 10; i++) {
      setFocus(container, focused: false);
      setFocus(container, focused: true);
      await tester.pump();
    }
    expect(service.calls.length, 1);
    await quiesce(tester, container);
  });

  testWidgets('a title change reads nothing, however often it fires', (
    tester,
  ) async {
    final container = await pumpChip(tester);
    for (var i = 0; i < 5; i++) {
      clock.now = clock.now.add(const Duration(minutes: 5));
      publish(container, const SessionChange.renamed('s1'));
      await tester.pump();
      await tester.pump();
    }
    expect(
      service.calls.length,
      1,
      reason: "the store sweep's title sync moves no quota",
    );
    await quiesce(tester, container);
  });

  testWidgets('a status change asks — and cannot ask inside the floor', (
    tester,
  ) async {
    // **The trigger that was costing the 429s.** A run ending is the moment
    // usage actually moved, so it is worth a request; but it fires on every
    // launch, every pane that stops and every coarse `bump()`, and it used to
    // mean an unconditional one. With several agents finishing runs it out-ran
    // the poll interval it was supposed to sit inside.
    final container = await pumpChip(tester);

    publish(container, const SessionChange.statusChanged('s1'));
    await tester.pump();
    await tester.pump();
    expect(
      service.calls.length,
      1,
      reason: 'seconds after a reading, a run ending cannot have moved a point',
    );

    clock.now = clock.now.add(usageFixtureFloor);
    publish(container, const SessionChange.statusChanged('s1'));
    await tester.pump();
    await tester.pump();
    expect(
      service.calls.length,
      2,
      reason: 'past the floor it is the best moment there is to ask',
    );
    await quiesce(tester, container);
  });

  testWidgets('twenty runs ending at once cost one request', (tester) async {
    final container = await pumpChip(tester, sessions: 20);
    clock.now = clock.now.add(usageFixtureFloor);
    for (var i = 1; i <= 20; i++) {
      publish(container, SessionChange.statusChanged('s$i'));
      await tester.pump();
      await tester.pump();
    }
    expect(
      service.calls.length,
      2,
      reason: 'one mount, one ask — the other nineteen are inside the floor',
    );
    await quiesce(tester, container);
  });

  testWidgets('one status change costs one read whatever the workspace holds', (
    tester,
  ) async {
    // The fan-out check: one subscription in the policy, not one per row.
    final container = await pumpChip(tester, sessions: 100);
    clock.now = clock.now.add(usageFixtureFloor);
    publish(container, const SessionChange.statusChanged('s42'));
    await tester.pump();
    await tester.pump();

    expect(service.calls.length, 2, reason: '100 sessions, one request');
    await quiesce(tester, container);
  });

  testWidgets('a hundred panes on one account share one fetch and one timer', (
    tester,
  ) async {
    // The property that lets the chip be per pane at all. Every one of these
    // draws a number; between them they cost the one request the account's
    // quota is worth, and they hold the one timer keyed on that account.
    final container = await pumpChip(tester, sessions: 100);
    expect(find.byIcon(AppIcons.circleHalf), findsNWidgets(100));
    expect(service.calls.length, 1, reason: '100 chips, one request');

    await elapse(tester, usageFixtureFloor);
    expect(service.calls.length, 2, reason: 'and one per tick, not a hundred');
    expect(policyOf(container).isPolling, isTrue);
    await quiesce(tester, container);
  });

  testWidgets('a second account gets its own reading and its own timer', (
    tester,
  ) async {
    // Two quotas are two quotas: the whole reason the chip moved out of the
    // window's status bar, where one figure spoke for both.
    db = seedUsageDatabase();
    AgentInstallationDao(
      db,
    ).insert(agentInstallation(id: 'a2', agentId: AgentIds.codex));
    SessionDao(db).insert(session(id: 's2', agentInstallationId: 'a2'));
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(clock),
        agentUsageServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                UsageChip(sessionId: 's1'),
                UsageChip(sessionId: 's2'),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(service.calls.length, 2, reason: 'one request per account');
    expect(service.calls.map((i) => i.agentId).toSet(), {
      AgentIds.claudeCode,
      AgentIds.codex,
    });
    final codexAccount = usageAccountKey(
      agentInstallation(id: 'a2', agentId: AgentIds.codex),
    );
    expect(policyOf(container).isPolling, isTrue);
    expect(
      container.read(usageRefreshProvider(codexAccount).notifier).isPolling,
      isTrue,
      reason: 'a second quota needs a second schedule, not a share of one',
    );
    setFocus(container, focused: false);
    await tester.pump();
  });

  testWidgets('a status change while blurred reads nothing', (tester) async {
    final container = await pumpChip(tester);
    setFocus(container, focused: false);
    await tester.pump();

    clock.now = clock.now.add(const Duration(hours: 1));
    publish(container, const SessionChange.statusChanged('s1'));
    await tester.pump();
    await tester.pump();
    expect(service.calls.length, 1);
    await quiesce(tester, container);
  });

  testWidgets('the timer dies when the chip goes away', (tester) async {
    final container = await pumpChip(tester, withOtherAgent: true);
    final policy = policyOf(container);
    expect(policy.isPolling, isTrue);

    // The app's own way of losing the chip: the pane on screen runs an agent
    // we have no usage endpoint for. Nothing watches the policy any more.
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: UsageChip(sessionId: 'other')),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1));

    expect(find.byIcon(AppIcons.circleHalf), findsNothing);
    expect(
      policy.isPolling,
      isFalse,
      reason: 'a leaked timer holds the container alive forever',
    );
  });

  testWidgets('the last pane closing leaves no timer, and the first to '
      'close leaves it', (tester) async {
    final container = await pumpChip(tester, sessions: 2);
    final policy = policyOf(container);
    expect(policy.isPolling, isTrue);

    Future<void> show(int chips) => tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                for (var i = 1; i <= chips; i++) UsageChip(sessionId: 's$i'),
              ],
            ),
          ),
        ),
      ),
    );

    await show(1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(
      policy.isPolling,
      isTrue,
      reason: 'one pane closing must not stop the account its sibling shares',
    );

    await show(0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(policy.isPolling, isFalse, reason: 'nothing outlives the last chip');
  });

  testWidgets('the timer dies with the widget tree', (tester) async {
    // Riverpod cancels its own scheduled auto-dispose when the surrounding
    // scope unmounts, so the chip's `dispose` is the only hook that always
    // runs — and a timer that outlived the tree is what failed eleven
    // unrelated tests in the suite.
    final container = await pumpChip(tester);
    final policy = policyOf(container);
    expect(policy.isPolling, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());

    expect(policy.isPolling, isFalse, reason: 'nothing outlives the chip');
  });

  testWidgets('a tick that lands after disposal asks for nothing', (
    tester,
  ) async {
    final container = await pumpChip(tester);
    final policy = policyOf(container);
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();

    // The case a bare `cancel()` misses: a timer that already fired, or an
    // in-flight fetch, calling back into a container that has gone.
    expect(policy.refresh, returnsNormally);
    expect(policy.isPolling, isFalse);
  });

  testWidgets('a pane running another agent starts no timer at all', (
    tester,
  ) async {
    // See the note above: `antigravity` now has a usage endpoint, so it cannot
    // stand for an agent that has none.
    db = seedUsageDatabase(agentId: 'unknownAgent');
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(clock),
        agentUsageServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Center(child: UsageChip(sessionId: 's1')),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(minutes: 30));

    expect(service.calls, isEmpty);
  });

  test(
    'retaining does not arm the tick inside the caller, but does arm it',
    () async {
      // A chip calls `retain` from its `build`, and arming reads
      // `windowFocusedProvider`. Mounting a provider inside a widget build marks
      // the tree dirty mid-build, which Flutter throws on — and it throws where
      // it costs most: the holder is already recorded, so the unwound build
      // leaves an account with a chip on screen and no timer behind it. Usage
      // then stops refreshing and nothing says so.
      //
      // Observed in the field before this was deferred: six
      // `UncontrolledProviderScope ... already in the process of building
      // widgets` reports naming `UsageChip` in half an hour of ordinary use.
      db = seedUsageDatabase();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(clock),
          agentUsageServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);

      // Focused, or arming is refused for a reason that has nothing to do
      // with what this test is about.
      container.read(windowFocusedProvider.notifier).set(true);
      // Held alive the way a chip on screen holds it: the provider is
      // autoDispose, and an unwatched controller is gone by the next
      // microtask — which is precisely when the deferred arm runs.
      final alive = container.listen(
        usageRefreshProvider(claudeAccount),
        (_, _) {},
      );
      addTearDown(alive.close);
      final policy = container.read(
        usageRefreshProvider(claudeAccount).notifier,
      );
      // `build` arms one of its own; this test is about what `retain` adds.
      policy.stopPolling();
      expect(policy.isPolling, isFalse);

      policy.retain(Object());
      expect(
        policy.isPolling,
        isFalse,
        reason: 'arming inside the caller is what reaches a provider mid-build',
      );

      await Future<void>.delayed(Duration.zero);
      expect(
        policy.isPolling,
        isTrue,
        reason: 'deferred, not dropped — the chip must still get its tick',
      );
      policy.stopPolling();
    },
  );
}
