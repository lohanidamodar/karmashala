import 'package:karmashala/src/app/companion/companion_lifecycle.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_remote/remote.dart';
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

  group('every state says whether the app is on screen', () {
    test('the mapping — inactive is still in front of somebody', () {
      const foreground = CompanionVisibility.foreground;
      const background = CompanionVisibility.background;
      expect(
        {
          for (final state in AppLifecycleState.values)
            state: CompanionLifecycleReconnector.visibilityOf(state),
        },
        {
          AppLifecycleState.resumed: foreground,
          AppLifecycleState.inactive: foreground,
          AppLifecycleState.hidden: background,
          AppLifecycleState.paused: background,
          AppLifecycleState.detached: background,
        },
      );
    });

    test('a pause reports, even though it dials nothing', () async {
      // The whole point: a phone that is connected and out of sight used to
      // say nothing at all, and the desktop suppressed its push on the strength
      // of the live link alone.
      final gateway = FakeCompanionGateway.paired();
      final reconnector = CompanionLifecycleReconnector(gateway);

      reconnector.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);

      expect(gateway.reconnectRequests, 0);
      expect(
        gateway.presenceReports.single.visibility,
        CompanionVisibility.background,
      );
    });

    test('one report per change, and nothing on a timer', () async {
      final gateway = FakeCompanionGateway.paired();
      final reconnector = CompanionLifecycleReconnector(gateway);

      reconnector.didChangeAppLifecycleState(AppLifecycleState.paused);
      reconnector.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);

      expect(gateway.presenceReports.map((p) => p.visibility), [
        CompanionVisibility.background,
        CompanionVisibility.foreground,
      ], reason: 'a lifecycle change is one report; nothing else produces any');
    });
  });
}
