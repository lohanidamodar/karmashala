import 'dart:async';

import 'package:karmashala/src/features/agents/data/agent_hook_receiver.dart';
import 'package:karmashala/src/features/agents/data/agent_status_service.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/notifications/application/session_status_registry.dart';
import 'package:karmashala/src/features/notifications/domain/agent_session_key.dart';
import 'package:karmashala/src/features/notifications/domain/watched_session.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/agent_status_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// How many rows the Explorer is asked to draw. The audit's number: roughly a
/// hundred session cards is what a busy workspace shows, and it is where the
/// old per-card poller cost ~83 provider ticks and up to ~10 whole CLI-store
/// scans **per second**.
const _rows = 100;

void main() {
  late AgentHookReports reports;
  late AgentHookReceiver receiver;
  late List<WatchedSession> watched;
  late int scans;
  late SessionStatusRegistry registry;

  setUp(() {
    final clock = FixedClock(testTime);
    reports = AgentHookReports();
    receiver = AgentHookReceiver(
      registry: AgentRegistry.builtIn,
      reports: reports,
      clock: clock,
    );
    watched = [
      for (var i = 0; i < _rows; i++)
        WatchedSession(
          key: AgentSessionKey(AgentIds.claudeCode, 'cli-$i'),
          label: 'Session $i',
          openId: 'row-$i',
          imported: false,
        ),
    ];
    scans = 0;
    registry = SessionStatusRegistry(
      statusService: AgentStatusService(
        registry: AgentRegistry.builtIn,
        hookReports: reports,
        clock: clock,
      ),
      agents: AgentRegistry.builtIn,
      loadSessions: () => watched,
      clock: clock,
      resolveTranscripts: () async {
        scans++;
        return const {};
      },
    );
    addTearDown(registry.dispose);
  });

  ProviderContainer container() {
    final container = ProviderContainer(
      overrides: [sessionStatusRegistryProvider.overrideWithValue(registry)],
    );
    addTearDown(container.dispose);
    return container;
  }

  void hookAll(String event) {
    for (var i = 0; i < _rows; i++) {
      receiver.handle(
        agentId: AgentIds.claudeCode,
        event: event,
        body: '{"session_id":"cli-$i"}',
      );
    }
  }

  test('$_rows status subscriptions start no timer and no store scan', () async {
    // Counted in a zone, because "the badge starts its own poll" is exactly
    // the shape of the bug: a `Future.delayed` per rendered row. Zero-duration
    // timers are event-loop yields, not polling, and are not counted.
    var timers = 0;
    await runZoned(
      () async {
        final read = container();
        for (var i = 0; i < _rows; i++) {
          read.listen(agentSessionStatusProvider('row-$i'), (_, _) {});
        }
        for (var i = 0; i < 8; i++) {
          await Future<void>.value();
        }
      },
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, f) {
          if (duration > Duration.zero) timers++;
          return parent.createTimer(zone, duration, f);
        },
        createPeriodicTimer: (self, parent, zone, period, f) {
          timers++;
          return parent.createPeriodicTimer(zone, period, f);
        },
      ),
    );

    expect(timers, 0, reason: 'reading a status must not start a poll');
    expect(scans, 0, reason: 'and must not walk the CLI stores');
    expect(registry.cycles, 0, reason: 'nor make the registry do a pass');
  });

  testWidgets('rendering $_rows badges does no work of its own', (tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container(),
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                for (var i = 0; i < _rows; i++)
                  AgentStatusBadge(sessionId: 'row-$i', showLabel: true),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(scans, 0);
    expect(registry.cycles, 0);
    // The badges are drawn and honest about knowing nothing yet: the old code
    // reached this state by starting a hundred polling loops.
    expect(find.text('Unknown'), findsWidgets);
    // `testWidgets` fails the test if any timer is still pending here, which is
    // the second half of the assertion above.
  });

  testWidgets('one shared cycle answers every rendered badge', (tester) async {
    hookAll('PreToolUse');
    final read = container();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: read,
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                for (var i = 0; i < _rows; i++)
                  AgentStatusBadge(sessionId: 'row-$i', showLabel: true),
              ],
            ),
          ),
        ),
      ),
    );

    await registry.cycle();
    await tester.pumpAndSettle();

    expect(registry.cycles, 1, reason: 'one pass, not one per row');
    expect(registry.probes, 0, reason: 'a hook costs no disk read');
    expect(scans, 0, reason: 'and no store walk');
    // Every visible badge switched over on that single pass.
    expect(find.text('Working'), findsWidgets);
    expect(find.text('Unknown'), findsNothing);
  });

  testWidgets('scrolling the list does not change how much polling exists', (
    tester,
  ) async {
    // The property the audit asked for by name: status cost must not be a side
    // effect of layout.
    hookAll('PreToolUse');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container(),
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                for (var i = 0; i < _rows; i++)
                  SizedBox(
                    height: 40,
                    child: AgentStatusBadge(sessionId: 'row-$i'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await registry.cycle();
    await tester.pumpAndSettle();
    final after = registry.cycles;

    await tester.drag(find.byType(ListView), const Offset(0, -1200));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 1200));
    await tester.pumpAndSettle();

    expect(registry.cycles, after, reason: 'scrolling created no passes');
    expect(scans, 0);
  });
}
