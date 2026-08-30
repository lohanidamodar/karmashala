import 'package:chitragupta/src/features/companion/client/companion_gateway.dart';
import 'package:chitragupta/src/features/companion/client/fake_companion_gateway.dart';
import 'package:chitragupta/src/features/companion/presentation/inbox_screen.dart';
import 'package:chitragupta/src/features/companion/presentation/session_view_screen.dart';
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
}
