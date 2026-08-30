import 'package:chitragupta/src/app/companion/companion_lifecycle.dart';
import 'package:chitragupta/src/features/companion/client/companion_gateway.dart';
import 'package:chitragupta/src/features/companion/client/fake_companion_gateway.dart';
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

  test('resume with a healthy link leaves it alone', () async {
    final gateway = FakeCompanionGateway.paired();
    final reconnector = CompanionLifecycleReconnector(gateway);

    reconnector.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);

    expect(gateway.reconnectRequests, 0);
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
  });
}
