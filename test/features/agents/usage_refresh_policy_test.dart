import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_usage_providers.dart';
import 'package:karmashala/src/features/agents/application/usage_refresh_policy.dart';
import 'package:karmashala/src/app/theme/app_icons.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/presentation/usage_chip.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';
import 'usage_fixtures.dart';

class _MovableClock implements Clock {
  _MovableClock(this.now);
  DateTime now;
  @override
  DateTime nowUtc() => now.toUtc();
}

/// **When the quota is read again, and — more importantly — when it is not.**
///
/// One timer, cancelled outright on blur. The counted unit is a fetch: every
/// entry in `FakeAgentUsageService.calls` is one request that would have gone
/// to the vendor endpoint.
void main() {
  late AppDatabase db;
  late FakeAgentUsageService service;
  late _MovableClock clock;

  setUp(() {
    service = FakeAgentUsageService();
    clock = _MovableClock(testTime);
  });
  tearDown(() => db.close());

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
        child: const MaterialApp(
          home: Scaffold(body: Center(child: UsageChip())),
        ),
      ),
    );
    await tester.pump();
    return container;
  }

  UsageRefreshController policyOf(ProviderContainer container) =>
      container.read(usageRefreshProvider.notifier);

  void setFocus(ProviderContainer container, {required bool focused}) =>
      container.read(windowFocusedProvider.notifier).set(focused);

  void publish(ProviderContainer container, SessionChange change) =>
      container.read(sessionsRevisionProvider.notifier).changed(change);

  /// Leaves no pending timer behind, which `testWidgets` treats as a failure.
  Future<void> quiesce(WidgetTester tester, ProviderContainer container) async {
    setFocus(container, focused: false);
    await tester.pump();
  }

  testWidgets('reads once on mount, then once every interval while focused', (
    tester,
  ) async {
    final container = await pumpChip(tester);
    expect(service.calls.length, 1, reason: 'the chip fetches when it appears');
    expect(policyOf(container).isPolling, isTrue);

    await tester.pump(kUsageRefreshInterval);
    await tester.pump();
    expect(service.calls.length, 2);

    await tester.pump(kUsageRefreshInterval);
    await tester.pump();
    expect(service.calls.length, 3);
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

    await tester.pump(kUsageRefreshInterval * 5);
    await tester.pump();
    expect(service.calls.length, 1, reason: 'five intervals, no requests');
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

  testWidgets('a flurry of focus changes inside one interval costs nothing', (
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

  testWidgets('a status change reads once; a title change reads nothing', (
    tester,
  ) async {
    final container = await pumpChip(tester);

    publish(container, const SessionChange.renamed('s1'));
    await tester.pump();
    await tester.pump();
    expect(
      service.calls.length,
      1,
      reason: "the store sweep's title sync moves no quota",
    );

    publish(container, const SessionChange.statusChanged('s1'));
    await tester.pump();
    await tester.pump();
    expect(
      service.calls.length,
      2,
      reason: 'a run ending is the moment usage actually moved',
    );
    await quiesce(tester, container);
  });

  testWidgets('one status change costs one read whatever the workspace holds', (
    tester,
  ) async {
    // The fan-out check: one subscription in the policy, not one per row.
    final container = await pumpChip(tester, sessions: 100);
    publish(container, const SessionChange.statusChanged('s42'));
    await tester.pump();
    await tester.pump();

    expect(service.calls.length, 2, reason: '100 sessions, one request');
    await quiesce(tester, container);
  });

  testWidgets('a status change while blurred reads nothing', (tester) async {
    final container = await pumpChip(tester);
    setFocus(container, focused: false);
    await tester.pump();

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

    // The app's own way of losing the chip: focus a pane running an agent we
    // have no usage endpoint for. Nothing watches the policy any more.
    container.read(selectedSessionIdProvider.notifier).select('other');
    await tester.pump(const Duration(milliseconds: 1));

    expect(find.byIcon(AppIcons.circleHalf), findsNothing);
    expect(
      policy.isPolling,
      isFalse,
      reason: 'a leaked 60s timer holds the container alive forever',
    );
  });

  testWidgets('the timer dies with the widget tree', (tester) async {
    // Riverpod cancels its own scheduled auto-dispose when the surrounding
    // scope unmounts, so the chip's `dispose` is the only hook that always
    // runs — and a 60-second timer that outlived the tree is what failed
    // eleven unrelated tests in the suite.
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
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: Center(child: UsageChip())),
        ),
      ),
    );
    await tester.pump(kUsageRefreshInterval * 3);

    expect(service.calls, isEmpty);
  });
}
