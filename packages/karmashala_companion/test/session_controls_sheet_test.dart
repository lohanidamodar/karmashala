import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_companion/src/presentation/session_controls_sheet.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_remote/remote.dart';

import 'companion_test_support.dart';

/// The phone picks a session's model and permission mode, and says what that
/// did to the session running on the desktop.
void main() {
  FakeCompanionGateway gateway({CapabilitySet? capabilities}) =>
      FakeCompanionGateway(
          pairing: CompanionPairing(
            capabilities: capabilities ?? CapabilitySet.all,
            hostName: 'Desktop',
            hostId: DeviceId.parse(fakeHostId(0)),
          ),
          link: CompanionLinkState.connected,
        )
        ..sessionOptionsById['s1'] = const RemoteSessionOptions(
          sessionId: 's1',
          models: [
            RemoteChoice(id: 'opus[1m]', label: 'Opus (1M context)'),
            RemoteChoice(id: 'sonnet', label: 'Sonnet'),
          ],
          modelId: 'sonnet',
          permissions: [
            RemoteChoice(id: 'mode=plan', label: 'Plan mode'),
            RemoteChoice(id: 'mode=acceptEdits', label: 'Accept edits'),
          ],
          permissionDefaultLabel: 'Ask every time',
        );

  testWidgets('lists what the desktop offers, the chosen one marked', (
    tester,
  ) async {
    final fake = gateway();
    await pumpPhone(
      tester,
      gateway: fake,
      home: const SingleChildScrollView(
        child: SessionControls(sessionId: 's1'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Opus (1M context)'), findsOneWidget);
    expect(find.text('Plan mode'), findsOneWidget);
    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, 'Sonnet')).selected,
      isTrue,
    );
  });

  testWidgets('a pick is applied, and what it did is said', (tester) async {
    final fake = gateway()..configureOutcome = RemoteConfigureOutcome.afterTurn;
    await pumpPhone(
      tester,
      gateway: fake,
      home: const SingleChildScrollView(
        child: SessionControls(sessionId: 's1'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Plan mode'));
    await tester.pumpAndSettle();

    expect(fake.configured.single.permissionId, 'mode=plan');
    expect(fake.configured.single.modelId, isNull);
    expect(find.text('Switches when the agent finishes this turn.'), findsOne);
  });

  testWidgets('a phone without send_prompt can look but not change', (
    tester,
  ) async {
    final fake = gateway(
      capabilities: CapabilitySet.of(const [Capability.viewSessions]),
    );
    await pumpPhone(
      tester,
      gateway: fake,
      home: const SingleChildScrollView(
        child: SessionControls(sessionId: 's1'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Opus (1M context)'));
    await tester.pumpAndSettle();

    expect(fake.configured, isEmpty);
    expect(find.textContaining('not granted send_prompt'), findsOneWidget);
  });
}
