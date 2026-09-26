/// Pins the tiny contract the pairing dialog and the local-relay loop (77)
/// meet on: `pairingRelayEndpointsProvider` yields labelled relay endpoints,
/// defaults to exactly one "Internet" entry carrying the configured relay,
/// and is overridable without touching the dialog.
library;

import 'package:karmashala/src/features/remote/application/remote_access_controller.dart';
import 'package:karmashala/src/features/remote/pairing/pairing_relay_endpoints.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/memory_server_config.dart';

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer(overrides: []);
  });

  tearDown(() {
    container.dispose();
  });

  test('defaults to one Internet entry carrying the default relay', () {
    final endpoints = container.read(pairingRelayEndpointsProvider);

    expect(endpoints, hasLength(1));
    expect(endpoints.single.label, 'Internet');
    expect(endpoints.single.kind, PairingRelayKind.internet);
    expect(endpoints.single.url, Uri.parse(kDefaultRelayUrl));
  });

  test('follows the configured relay URL', () {
    setRemoteAccessNow(container, relayUrl: 'wss://my.relay.example');

    final endpoints = container.read(pairingRelayEndpointsProvider);
    expect(endpoints.single.url, Uri.parse('wss://my.relay.example'));
  });

  test('is overridable with a local entry, the way loop 77 feeds it', () {
    final local = PairingRelayEndpoint(
      label: 'Local network',
      url: Uri.parse('ws://192.168.1.20:7011'),
      kind: PairingRelayKind.local,
    );
    final overridden = ProviderContainer(
      overrides: [
        pairingRelayEndpointsProvider.overrideWith(
          (ref) => [
            local,
            PairingRelayEndpoint(
              label: 'Internet',
              url: Uri.parse(kDefaultRelayUrl),
              kind: PairingRelayKind.internet,
            ),
          ],
        ),
      ],
    );
    addTearDown(overridden.dispose);

    final endpoints = overridden.read(pairingRelayEndpointsProvider);
    expect(endpoints, hasLength(2));
    expect(endpoints.first, local, reason: 'value equality is part of the pin');
    expect(endpoints.first.kind, PairingRelayKind.local);
  });
}
