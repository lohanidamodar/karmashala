import 'package:karmashala/src/app/companion/companion_lifecycle.dart';
import 'package:karmashala/src/features/companion/client/companion_gateway.dart';
import 'package:karmashala/src/features/companion/client/fake_companion_gateway.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('resume with the link down asks for an immediate re-dial', () async {
    final gateway = FakeCompanionGateway.paired(
      link: CompanionLinkState.disconnected,
    );
    final reconnector = CompanionLifecycleReconnector(gateway);

    reconnector.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);

    expect(gateway.reconnectRequests, 1);
  });

  test('resume asks even when the link SAYS it is up — a socket nobody '
      'watched is a claim, not a fact', () async {
    // The old rule was to leave a healthy-looking link alone. But after the
    // app has been frozen, "connected" describes a socket Android may have
    // torn down without telling anyone, and the transport does not find out
    // until its next heartbeat — twenty-five seconds of a dead link on
    // screen. `reconnect()` proves a link that claims to be up, so the answer
    // is definite either way within one hello.
    final gateway = FakeCompanionGateway.paired();
    final reconnector = CompanionLifecycleReconnector(gateway);

    reconnector.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);

    expect(gateway.reconnectRequests, 1);
  });

  test('pausing never dials — the link rests until resume or FCM', () async {
    final gateway = FakeCompanionGateway.paired(
      link: CompanionLinkState.disconnected,
    );
    final reconnector = CompanionLifecycleReconnector(gateway);

    reconnector.didChangeAppLifecycleState(AppLifecycleState.inactive);
    reconnector.didChangeAppLifecycleState(AppLifecycleState.hidden);
    reconnector.didChangeAppLifecycleState(AppLifecycleState.paused);
    reconnector.didChangeAppLifecycleState(AppLifecycleState.detached);
    await Future<void>.delayed(Duration.zero);

    expect(gateway.reconnectRequests, 0);
  });

  testWidgets('hears real lifecycle events once attached', (tester) async {
    final gateway = FakeCompanionGateway.paired(
      link: CompanionLinkState.disconnected,
    );
    final reconnector = CompanionLifecycleReconnector(gateway);
    reconnector.attach(tester.binding);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(gateway.reconnectRequests, 1);

    // Detached observers hear nothing more.
    reconnector.detach();
    gateway.setLink(CompanionLinkState.disconnected);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(gateway.reconnectRequests, 1);
    // And a pause still dials nothing at all.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(gateway.reconnectRequests, 1);
  });
}
