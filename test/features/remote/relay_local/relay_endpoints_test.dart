/// Pins the seam the pairing dialog's tabs read: which endpoints are
/// offerable, their labels, URLs and kinds. Merge-time wiring connects this
/// to the dialog's own provider — the shape here is the contract.
library;

import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/features/remote/application/relay_prefs.dart';
import 'package:chitragupta/src/features/remote/application/remote_access_controller.dart';
import 'package:chitragupta/src/features/remote/relay_local/local_relay_providers.dart';
import 'package:chitragupta/src/features/remote/relay_local/local_relay_service.dart';
import 'package:chitragupta/src/features/remote/relay_local/relay_endpoints.dart';
import 'package:chitragupta/src/features/settings/application/settings_controller.dart';
import 'package:chitragupta/src/features/settings/domain/relay_mode.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _running = LocalRelayStatus(
  state: LocalRelayState.running,
  boundPort: 8787,
  endpoints: [
    LocalRelayEndpoint(
      ip: '192.168.1.7',
      interfaceName: 'Wi-Fi',
      port: 8787,
      primary: true,
      reachable: true,
    ),
    LocalRelayEndpoint(
      ip: '172.22.32.1',
      interfaceName: 'vEthernet (WSL)',
      port: 8787,
      primary: false,
      reachable: true,
    ),
  ],
);

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  ProviderContainer containerWith(LocalRelayStatus status) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        localRelayStatusProvider.overrideWithValue(status),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('remote access off offers nothing', () {
    final container = containerWith(_running);

    expect(container.read(relayEndpointsProvider), isEmpty);
  });

  test('hosted mode offers the internet endpoint (default URL)', () {
    final container = containerWith(const LocalRelayStatus.stopped());
    container
        .read(settingsControllerProvider.notifier)
        .setRemoteAccessEnabled(true);

    expect(container.read(relayEndpointsProvider), [
      RelayEndpointOption(
        label: 'Internet',
        url: Uri.parse(kDefaultRelayUrl),
        kind: RelayEndpointKind.internet,
      ),
    ]);
  });

  test('a self-hosted URL is the internet endpoint verbatim', () {
    final container = containerWith(const LocalRelayStatus.stopped());
    container.read(settingsControllerProvider.notifier)
      ..setRemoteAccessEnabled(true)
      ..setRemoteRelayUrl('wss://relay.example.com:8443');

    expect(
      container.read(relayEndpointsProvider).single.url,
      Uri.parse('wss://relay.example.com:8443'),
    );
  });

  test('local mode with the relay running offers its primary LAN URL', () {
    final container = containerWith(_running);
    container.read(settingsControllerProvider.notifier)
      ..setRemoteAccessEnabled(true)
      ..setRemoteRelayMode(RelayMode.local);

    expect(container.read(relayEndpointsProvider), [
      RelayEndpointOption(
        label: 'Local network',
        url: Uri.parse('ws://192.168.1.7:8787'),
        kind: RelayEndpointKind.local,
      ),
    ]);
  });

  test('local mode offers nothing while the relay cannot be dialled', () {
    for (final status in [
      const LocalRelayStatus.stopped(),
      const LocalRelayStatus(
        state: LocalRelayState.error,
        error: 'port 8787 is already in use by another program',
      ),
      // Running, but no LAN address a phone could reach.
      const LocalRelayStatus(state: LocalRelayState.running, boundPort: 8787),
    ]) {
      final container = containerWith(status);
      container.read(settingsControllerProvider.notifier)
        ..setRemoteAccessEnabled(true)
        ..setRemoteRelayMode(RelayMode.local);

      expect(
        container.read(relayEndpointsProvider),
        isEmpty,
        reason: 'a tab offering an undialable endpoint would only pretend',
      );
    }
  });

  group('both relays at once (loop 80)', () {
    test('both switched on offers two endpoints, local first', () {
      final container = containerWith(_running);
      container
          .read(settingsControllerProvider.notifier)
          .setRemoteAccessEnabled(true);
      container.read(relayPrefsProvider.notifier)
        ..setLocalEnabled(true)
        ..setHostedEnabled(true);

      final offered = container.read(relayEndpointsProvider);

      expect(offered, hasLength(2));
      // Local first: on the network the phone shares it always works.
      expect(offered[0].label, 'Local network');
      expect(offered[0].kind, RelayEndpointKind.local);
      expect(offered[0].url, Uri.parse('ws://192.168.1.7:8787'));
      expect(offered[1].kind, RelayEndpointKind.internet);
      expect(offered[1].url, Uri.parse(kDefaultRelayUrl));
    });

    test('only the local switch offers one local endpoint', () {
      final container = containerWith(_running);
      container
          .read(settingsControllerProvider.notifier)
          .setRemoteAccessEnabled(true);
      container.read(relayPrefsProvider.notifier)
        ..setLocalEnabled(true)
        ..setHostedEnabled(false);

      expect(container.read(relayEndpointsProvider), [
        RelayEndpointOption(
          label: 'Local network',
          url: Uri.parse('ws://192.168.1.7:8787'),
          kind: RelayEndpointKind.local,
        ),
      ]);
    });

    test('both switched off offers nothing, however healthy the relay', () {
      final container = containerWith(_running);
      container
          .read(settingsControllerProvider.notifier)
          .setRemoteAccessEnabled(true);
      container.read(relayPrefsProvider.notifier)
        ..setLocalEnabled(false)
        ..setHostedEnabled(false);

      expect(
        container.read(relayEndpointsProvider),
        isEmpty,
        reason: 'nothing is listening, so nothing may be offered',
      );
    });

    test('local on but not yet running offers only the hosted endpoint', () {
      final container = containerWith(const LocalRelayStatus.stopped());
      container
          .read(settingsControllerProvider.notifier)
          .setRemoteAccessEnabled(true);
      container.read(relayPrefsProvider.notifier)
        ..setLocalEnabled(true)
        ..setHostedEnabled(true);

      final offered = container.read(relayEndpointsProvider);

      expect(offered, hasLength(1));
      expect(offered.single.kind, RelayEndpointKind.internet);
    });
  });
}
