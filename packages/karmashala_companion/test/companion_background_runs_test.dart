import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_companion/widgets.dart';
import 'package:karmashala_remote/companion.dart';

import 'companion_test_support.dart';

/// The background runs a session is waiting on, listed on the phone above
/// its composer — after the turn that launched them ended, so with no
/// running call at all.
void main() {
  testWidgets('two background agents are listed with their state and how '
      'long each has run', (tester) async {
    final fake = FakeCompanionGateway.paired(sessions: [summary('s1')]);
    await pumpPhone(
      tester,
      gateway: fake,
      home: const Column(
        children: [CompanionBackgroundRuns(sessionId: 's1')],
      ),
    );
    fake.setActivity(
      's1',
      CompanionActivity(
        at: DateTime.now(),
        background: const [
          CompanionBackgroundRun(
            agent: true,
            state: 'running',
            description: 'Strip idle detection',
            elapsed: Duration(minutes: 5, seconds: 19),
          ),
          CompanionBackgroundRun(
            agent: true,
            state: 'completed',
            description: 'Unify tasks and work items',
            elapsed: Duration(minutes: 2),
          ),
        ],
      ),
    );
    await tester.pump();

    expect(find.text('1 background agent running'), findsOneWidget);
    expect(find.text('Strip idle detection'), findsOneWidget);
    expect(find.textContaining('running · 5m 19s'), findsOneWidget);
    expect(find.text('Unify tasks and work items'), findsOneWidget);
    expect(find.textContaining('done · 2m'), findsOneWidget);
  });

  testWidgets('with none there is nothing', (tester) async {
    final fake = FakeCompanionGateway.paired(sessions: [summary('s1')]);
    await pumpPhone(
      tester,
      gateway: fake,
      home: const Column(
        children: [CompanionBackgroundRuns(sessionId: 's1')],
      ),
    );
    fake.setActivity('s1', CompanionActivity(at: DateTime.now()));
    await tester.pump();

    expect(tester.getSize(find.byType(CompanionBackgroundRuns)), Size.zero);
  });
}
