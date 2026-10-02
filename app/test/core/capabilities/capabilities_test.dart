import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala_ui/tokens.dart' show UiDensity;

/// A server feature reaches a surface as one named getter on [Capabilities],
/// true exactly when the server's welcome named it.
void main() {
  const client = ClientCapabilities(
    systemIntegration: true,
    osToasts: true,
    localNotifications: false,
    localDevices: true,
    externalApps: true,
    fileDrop: true,
    relaunch: true,
    density: UiDensity.pointer,
    hostsServer: true,
    multicastLock: false,
    mediaPlayback: true,
    deviceName: 'desk',
    camera: false,
  );

  Capabilities withFeatures(Set<String> features) => Capabilities(
    client: client,
    server: ServerOffer(sameMachine: true, features: features),
  );

  test('acpSessions follows the acpSessions feature', () {
    expect(withFeatures(const {}).acpSessions, isFalse);
    expect(withFeatures(const {'sessions.transcript'}).acpSessions, isFalse);
    expect(withFeatures(const {'acpSessions'}).acpSessions, isTrue);
  });

  test('chatViaServer follows sessions.transcript, independently', () {
    expect(withFeatures(const {'acpSessions'}).chatViaServer, isFalse);
    expect(
      withFeatures(const {'sessions.transcript', 'acpSessions'}).chatViaServer,
      isTrue,
    );
  });

  test('a server that has not said hello offers nothing', () {
    const offer = ServerOffer(sameMachine: false);
    const capabilities = Capabilities(client: client, server: offer);
    expect(capabilities.acpSessions, isFalse);
    expect(capabilities.chatViaServer, isFalse);
  });
}
