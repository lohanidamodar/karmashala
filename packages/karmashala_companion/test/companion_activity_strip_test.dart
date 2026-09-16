import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_companion/widgets.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import 'companion_test_support.dart';

/// The activity strip above the phone's composer.
void main() {
  CompanionActivity running() => CompanionActivity(
    at: DateTime.now(),
    calls: const [
      CompanionActivityCall(
        summary: 'Bash(flutter test)',
        elapsed: Duration(seconds: 12),
      ),
    ],
  );

  testWidgets('its clock is started by the state, never from build', (
    tester,
  ) async {
    final fake = FakeCompanionGateway.paired(sessions: [summary('s1')]);
    final builtTimers = <String>[];
    await runZoned(
      () async {
        await pumpPhone(
          tester,
          gateway: fake,
          home: const Column(children: [CompanionActivityStrip(sessionId: 's1')]),
        );
        fake.setActivity('s1', running());
        await tester.pump();
        // A rebuild from above must not start a second clock either.
        await tester.pump(kActivityTickInterval);
      },
      zoneSpecification: ZoneSpecification(
        createPeriodicTimer: (self, parent, zone, period, f) {
          final stack = StackTrace.current.toString();
          if (stack.contains('_CompanionActivityStripState.build')) {
            builtTimers.add(stack);
          }
          return parent.createPeriodicTimer(zone, period, f);
        },
      ),
    );

    expect(find.text('Bash(flutter test)'), findsOneWidget);
    expect(builtTimers, isEmpty);
  });

  testWidgets('it stays up while a call runs, and folds when it ends', (
    tester,
  ) async {
    final fake = FakeCompanionGateway.paired(sessions: [summary('s1')]);
    await pumpPhone(
      tester,
      gateway: fake,
      home: const Column(children: [CompanionActivityStrip(sessionId: 's1')]),
    );
    fake.setActivity('s1', running());
    await tester.pump();
    await tester.pump(kActivityTickInterval * 2);
    expect(find.text('Bash(flutter test)'), findsOneWidget);

    fake.setActivity('s1', CompanionActivity.unknown);
    await tester.pump();
    expect(tester.getSize(find.byType(CompanionActivityStrip)).height, 0);
  });

  testWidgets('it draws at a thumb’s sizes, not the desktop pointer’s', (
    tester,
  ) async {
    final fake = FakeCompanionGateway.paired(sessions: [summary('s1')]);
    await pumpPhone(
      tester,
      gateway: fake,
      home: const Column(children: [CompanionActivityStrip(sessionId: 's1')]),
    );
    fake.setActivity('s1', running());
    await tester.pump();

    // The working glyph is the shared spinner, at the touch step.
    final icon = tester.widget<WorkingSpinner>(
      find.descendant(
        of: find.byType(CompanionActivityStrip),
        matching: find.byType(WorkingSpinner),
      ),
    );
    expect(icon.size, Touch.iconSmall);
    final label = tester.widget<Text>(find.text('Bash(flutter test)'));
    expect(label.style?.fontSize, greaterThan(MonoStyles.small.fontSize!));
  });
}
