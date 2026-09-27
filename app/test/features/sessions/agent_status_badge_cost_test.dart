import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/agent_status_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_data_server.dart';

/// How many rows the Explorer is asked to draw. The audit's number: roughly a
/// hundred session cards is what a busy workspace shows, and it is where the
/// old per-card poller cost ~83 provider ticks and up to ~10 whole CLI-store
/// scans **per second**. Since slice 5c the server keeps every status and
/// tells this app each move: a badge reads the copy, and asks nothing.
const _rows = 100;

void main() {
  late FakeDataServer server;

  setUp(() => server = FakeDataServer());

  Future<ProviderContainer> container() async {
    final container = ProviderContainer(overrides: [await server.override()]);
    addTearDown(container.dispose);
    return container;
  }

  void allWorking() {
    for (var i = 0; i < _rows; i++) {
      server.attention.statusOf(
        'row-$i',
        AgentActivityStatus.working,
        sessionId: 'cli-$i',
        label: 'Session $i',
      );
    }
  }

  test('$_rows status subscriptions start no timer and ask nothing', () async {
    final read = await container();
    final asked = server.requests.length;
    // Counted in a zone, because "the badge starts its own poll" is exactly
    // the shape of the bug: a `Future.delayed` per rendered row. Zero-duration
    // timers are event-loop yields, not polling, and are not counted.
    var timers = 0;
    await runZoned(
      () async {
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
    expect(
      server.requests.length,
      asked,
      reason: 'nor ask the server anything: it tells',
    );
  });

  testWidgets('rendering $_rows badges does no work of its own', (
    tester,
  ) async {
    final read = await container();
    final asked = server.requests.length;
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
    await tester.pump();

    expect(server.requests.length, asked);
    // The badges are drawn and honest about knowing nothing yet.
    expect(find.text('Unknown'), findsWidgets);
    // `testWidgets` fails the test if any timer is still pending here.
  });

  testWidgets('what the server tells answers every rendered badge', (
    tester,
  ) async {
    final read = await container();
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
    final asked = server.requests.length;

    allWorking();
    await tester.pumpAndSettle();

    expect(server.requests.length, asked, reason: 'told, never asked');
    expect(find.text('Working'), findsWidgets);
    expect(find.text('Unknown'), findsNothing);
  });

  testWidgets('scrolling the list asks nothing', (tester) async {
    // The property the audit asked for by name: status cost must not be a side
    // effect of layout.
    allWorking();
    final read = await container();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: read,
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
    await tester.pumpAndSettle();
    final asked = server.requests.length;

    await tester.drag(find.byType(ListView), const Offset(0, -1200));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 1200));
    await tester.pumpAndSettle();

    expect(server.requests.length, asked, reason: 'scrolling asked nothing');
  });
}
