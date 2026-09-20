/// Choosing a desktop's route by hand, at phone size: the Route line on each
/// desktop, the picker behind it, and the banner's way back to Auto when a
/// pinned route stops answering.
library;

import 'package:karmashala_companion/widgets.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_remote/remote.dart' show CapabilitySet;
import 'package:flutter_test/flutter_test.dart';

import 'companion_test_support.dart';

void main() {
  final studio = fakeHostId(1);
  final box = fakeHostId(2);
  final hosted = Uri.parse(kDefaultCompanionRelayUrl);
  final onBox = Uri.parse('ws://198.51.100.7:8787/k/s3cr3t-token');

  CompanionConnection desktop({
    CompanionRoutePin pin = CompanionRoutePin.auto,
    List<Uri>? relays,
  }) => CompanionConnection(
    hostId: studio,
    name: 'Studio',
    active: true,
    pin: pin,
    relays: relays ?? [hosted, onBox],
  );

  testWidgets('a desktop says how it is reached; a directly paired box has no '
      'route to choose', (tester) async {
    final gateway = FakeCompanionGateway.paired(
      connections: [
        desktop(),
        CompanionConnection(
          hostId: box,
          name: 'do-box',
          active: false,
          route: HostRoute.direct,
          directEndpoint: '198.51.100.7:47820',
        ),
      ],
    );
    await pumpPhone(tester, gateway: gateway, home: const ConnectionsSection());

    expect(find.textContaining('Route: Automatic'), findsOneWidget);
  });

  testWidgets('the picker offers what the desktop announced, never shows a '
      "relay's token, and pins the one chosen", (tester) async {
    final gateway = FakeCompanionGateway.paired(connections: [desktop()]);
    await pumpPhone(tester, gateway: gateway, home: const ConnectionsSection());

    await tester.tap(find.textContaining('Route: Automatic'));
    await tester.pumpAndSettle();

    expect(find.text('Automatic'), findsOneWidget);
    expect(find.text('This network (LAN)'), findsOneWidget);
    expect(find.text('Hosted relay'), findsOneWidget);
    expect(find.text('Relay at 198.51.100.7:8787'), findsOneWidget);
    expect(find.textContaining('s3cr3t'), findsNothing);

    await tester.tap(find.text('Relay at 198.51.100.7:8787'));
    await tester.pumpAndSettle();

    expect(gateway.routePinRequests, [
      (studio, CompanionRoutePin.relay(onBox)),
    ]);
    expect(
      find.textContaining('Route: Relay at 198.51.100.7:8787 (pinned)'),
      findsOneWidget,
    );
  });

  testWidgets('a pinned relay the desktop stopped offering says so, and stays '
      'pinned rather than quietly turning Automatic', (tester) async {
    final gateway = FakeCompanionGateway.paired(
      connections: [
        desktop(pin: CompanionRoutePin.relay(onBox), relays: [hosted]),
      ],
    );
    await pumpPhone(tester, gateway: gateway, home: const ConnectionsSection());

    expect(
      find.textContaining('no longer offered by the desktop'),
      findsOneWidget,
    );

    await tester.tap(find.textContaining('Route: Relay at'));
    await tester.pumpAndSettle();
    // Still offered, so the person can see what they chose.
    expect(find.text('Relay at 198.51.100.7:8787'), findsOneWidget);
  });

  testWidgets('a pinned desktop that is not answering offers Use Auto on the '
      'banner', (tester) async {
    final gateway = FakeCompanionGateway(
      pairing: CompanionPairing(
        capabilities: CapabilitySet.all,
        hostName: 'Studio',
      ),
      connections: [desktop(pin: CompanionRoutePin.lan)],
    );
    await pumpPhone(tester, gateway: gateway, home: const LinkBanner());

    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Use Auto'));
    await tester.pumpAndSettle();

    expect(gateway.routePinRequests, [(studio, CompanionRoutePin.auto)]);
  });

  testWidgets('an automatic desktop that is not answering offers Retry alone', (
    tester,
  ) async {
    final gateway = FakeCompanionGateway(
      pairing: CompanionPairing(capabilities: CapabilitySet.all),
      connections: [desktop()],
    );
    await pumpPhone(tester, gateway: gateway, home: const LinkBanner());

    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Use Auto'), findsNothing);
  });
}
