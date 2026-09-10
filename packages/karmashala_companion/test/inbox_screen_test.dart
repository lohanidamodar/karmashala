import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_companion/screens.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'companion_test_support.dart';

/// The attention inbox on the phone: only waiting sessions, newest first,
/// each one tap from its transcript.
void main() {
  testWidgets('lists only sessions the host says are waiting', (tester) async {
    final now = DateTime.now().toUtc();
    final gateway = FakeCompanionGateway.paired(
      sessions: [
        summary(
          's1',
          title: 'Fix the login flow',
          attention: CompanionAttention(
            kind: CompanionAttentionKind.needsYou,
            at: now.subtract(const Duration(minutes: 3)),
          ),
        ),
        summary('s2', title: 'Quiet session'),
        summary(
          's3',
          title: 'Broken build',
          attention: CompanionAttention(
            kind: CompanionAttentionKind.failed,
            at: now,
          ),
        ),
      ],
    );
    await pumpPhone(tester, gateway: gateway, home: const InboxScreen());

    expect(find.text('Fix the login flow'), findsOneWidget);
    expect(find.text('Broken build'), findsOneWidget);
    expect(find.text('Quiet session'), findsNothing);
    expect(find.textContaining('Needs you'), findsOneWidget);
    expect(find.textContaining('Failed'), findsOneWidget);

    // Newest first: the failure arrived after the approval.
    final failedY = tester.getTopLeft(find.text('Broken build')).dy;
    final needsYouY = tester.getTopLeft(find.text('Fix the login flow')).dy;
    expect(failedY, lessThan(needsYouY));
  });

  testWidgets('tapping an item opens its session', (tester) async {
    final gateway = FakeCompanionGateway.paired(
      sessions: [
        summary(
          's1',
          title: 'Fix the login flow',
          attention: CompanionAttention(
            kind: CompanionAttentionKind.needsYou,
            at: DateTime.now().toUtc(),
          ),
        ),
      ],
    );
    await pumpPhone(tester, gateway: gateway, home: const InboxScreen());

    await tester.tap(find.text('Fix the login flow'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionViewScreen), findsOneWidget);
  });

  testWidgets('an empty inbox says nothing needs you', (tester) async {
    final gateway = FakeCompanionGateway.paired(sessions: [summary('s1')]);
    await pumpPhone(tester, gateway: gateway, home: const InboxScreen());
    expect(find.text('Nothing needs you.'), findsOneWidget);
  });

  testWidgets('a long attention row survives 200% text on a phone', (
    tester,
  ) async {
    final gateway = FakeCompanionGateway.paired(
      sessions: [
        summary(
          's1',
          title: 'Rewrite the authentication middleware end to end',
          project: 'a-project-with-a-very-long-name',
          attention: CompanionAttention(
            kind: CompanionAttentionKind.needsYou,
            at: DateTime.now().toUtc().subtract(const Duration(hours: 4)),
          ),
        ),
      ],
    );
    await pumpPhone(
      tester,
      gateway: gateway,
      home: const InboxScreen(),
      textScale: 2.0,
    );

    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(InkWell).first).height,
      greaterThan(Touch.target),
      reason: 'the row grows with the text; it does not clip it',
    );
  });

  testWidgets('the empty inbox reads at 200% without overflowing', (
    tester,
  ) async {
    final gateway = FakeCompanionGateway.paired(sessions: [summary('s1')]);
    await pumpPhone(
      tester,
      gateway: gateway,
      home: const InboxScreen(),
      textScale: 2.0,
    );

    expect(find.text('Nothing needs you.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
