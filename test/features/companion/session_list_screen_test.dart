import 'package:chitragupta/src/app/theme/app_icons.dart';
import 'package:chitragupta/src/features/companion/client/companion_gateway.dart';
import 'package:chitragupta/src/features/companion/client/fake_companion_gateway.dart';
import 'package:chitragupta/src/features/companion/presentation/session_list_screen.dart';
import 'package:chitragupta/src/features/companion/presentation/session_view_screen.dart';
import 'package:chitragupta/src/features/explorer/presentation/session_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'companion_test_support.dart';

/// The phone's session list: the desktop's three-line cards, single column,
/// grouped under project headers, at 390×844.
void main() {
  testWidgets('renders the scripted sessions under their project headers', (
    tester,
  ) async {
    final gateway = FakeCompanionGateway.paired(
      sessions: [
        summary(
          's1',
          title: 'Fix the login flow',
          branch: 'fix/login',
          whereabouts: 'last seen 2h ago',
        ),
        summary('s2', title: 'Write the release notes'),
        summary('s3', title: 'Port the parser', project: 'chitragupta'),
      ],
    );
    await pumpPhone(tester, gateway: gateway, home: const SessionListScreen());

    // Project headers with their counts.
    expect(find.text('popupbits'), findsOneWidget);
    expect(find.text('chitragupta'), findsOneWidget);
    expect(find.text('2 sessions'), findsOneWidget);
    expect(find.text('1 session'), findsOneWidget);

    // The desktop card, reused: title, agent line, and line three verbatim.
    expect(find.byType(SessionCard), findsNWidgets(3));
    expect(find.text('Fix the login flow'), findsOneWidget);
    expect(find.text('Claude Code  ·  running'), findsNWidgets(3));
    expect(find.text('fix/login  ·  last seen 2h ago'), findsOneWidget);
  });

  testWidgets('a waiting session shows the attention badge and header count', (
    tester,
  ) async {
    final gateway = FakeCompanionGateway.paired(
      sessions: [
        summary(
          's1',
          status: CompanionSessionStatus.needsYou,
          attention: CompanionAttention(
            kind: CompanionAttentionKind.needsYou,
            at: DateTime.now().toUtc(),
          ),
        ),
        summary('s2'),
      ],
    );
    await pumpPhone(tester, gateway: gateway, home: const SessionListScreen());

    // The status badge's needs-you glyph on the card…
    expect(find.byIcon(AppIcons.warningCircle), findsOneWidget);
    // …and the header's attention clause, worded as the desktop words it.
    expect(find.textContaining('1 needs you'), findsOneWidget);
  });

  testWidgets('tapping a card opens the session view', (tester) async {
    final gateway = FakeCompanionGateway.paired(sessions: [summary('s1')]);
    await pumpPhone(tester, gateway: gateway, home: const SessionListScreen());

    await tester.tap(find.text('Session s1'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionViewScreen), findsOneWidget);
  });

  testWidgets('an empty host is said in words, not shown as a blank list', (
    tester,
  ) async {
    final gateway = FakeCompanionGateway.paired();
    await pumpPhone(tester, gateway: gateway, home: const SessionListScreen());
    expect(find.textContaining('No sessions on Desktop'), findsOneWidget);
  });

  testWidgets('the first frame is a loading state, not an empty claim', (
    tester,
  ) async {
    final gateway = FakeCompanionGateway.paired(sessions: [summary('s1')]);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // No settling pump: the stream has not delivered yet.
    await tester.pumpWidget(
      buildPhoneApp(gateway: gateway, home: const SessionListScreen()),
    );
    expect(find.textContaining('No sessions'), findsNothing);
  });
}
