/// The one-click switch, end to end below the UI: choosing "This computer"
/// brings the embedded relay up and points the host at its LAN URL, choosing
/// hosted (or disabling) tears it down. Loopback only — nothing binds 0.0.0.0.
library;

import 'dart:io';

import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/features/remote/application/remote_access_controller.dart';
import 'package:chitragupta/src/features/remote/application/remote_host_service.dart';
import 'package:chitragupta/src/features/remote/data/paired_device_dao.dart';
import 'package:chitragupta/src/features/remote/protocol.dart';
import 'package:chitragupta/src/features/remote/relay_local/local_relay_providers.dart';
import 'package:chitragupta/src/features/remote/relay_local/local_relay_service.dart';
import 'package:chitragupta/src/features/settings/application/settings_controller.dart';
import 'package:chitragupta/src/features/settings/domain/relay_mode.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fake_bindings.dart';

void main() {
  late AppDatabase db;
  late LocalRelayService localRelay;
  late ProviderContainer container;
  late RemoteAccessController controller;
  late SettingsController settings;

  setUp(() {
    db = AppDatabase.memory();
    localRelay = LocalRelayService(
      bindAddress: '127.0.0.1',
      interfaces: () async => [(name: 'lo', ip: '127.0.0.1')],
    );
    final fake = FakeRemoteBindings();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        localRelayServiceProvider.overrideWithValue(localRelay),
        remoteAccessControllerProvider.overrideWith(
          (ref) => RemoteAccessController(
            ref,
            serviceFactory: (relayUri) => RemoteHostService(
              devices: PairedDeviceDao(db),
              hostId: DeviceId.parse('11111111222222223333333344444444'),
              bindings: fake.bindings,
              relay: relayUri,
              lanPort: 0,
              advertise: false,
              transcriptPollInterval: Duration.zero,
            ),
          ),
        ),
      ],
    );
    controller = container.read(remoteAccessControllerProvider);
    settings = container.read(settingsControllerProvider.notifier);
  });

  tearDown(() async {
    await controller.shutdown();
    await localRelay.stop();
    container.dispose();
    db.close();
  });

  test(
    'choosing "This computer" starts the relay and the host dials it',
    () async {
      settings.setRemoteAccessEnabled(true);
      settings.setRemoteRelayMode(RelayMode.local);
      settings.setLocalRelayPort(0);

      await controller.sync();

      expect(localRelay.isRunning, isTrue);
      final port = localRelay.status.boundPort!;
      expect(controller.isRunning, isTrue);
      expect(controller.service!.relay, Uri.parse('ws://127.0.0.1:$port'));
      // The relay the host will hand to the QR is genuinely serving.
      final client = HttpClient();
      final response = await (await client.getUrl(
        Uri.parse('http://127.0.0.1:$port/healthz'),
      )).close();
      expect(response.statusCode, 200);
      client.close(force: true);
    },
  );

  test('switching to hosted stops the local relay', () async {
    settings.setRemoteAccessEnabled(true);
    settings.setRemoteRelayMode(RelayMode.local);
    settings.setLocalRelayPort(0);
    await controller.sync();
    expect(localRelay.isRunning, isTrue);

    settings.setRemoteRelayMode(RelayMode.hosted);
    settings.setRemoteRelayUrl('wss://relay.example.com');
    await controller.sync();

    expect(localRelay.status.state, LocalRelayState.stopped);
    expect(controller.service!.relay, Uri.parse('wss://relay.example.com'));
  });

  test('disabling remote access stops relay and host together', () async {
    settings.setRemoteAccessEnabled(true);
    settings.setRemoteRelayMode(RelayMode.local);
    settings.setLocalRelayPort(0);
    await controller.sync();
    final port = localRelay.status.boundPort!;

    settings.setRemoteAccessEnabled(false);
    await controller.sync();

    expect(controller.service, isNull);
    expect(localRelay.status.state, LocalRelayState.stopped);
    // The port really is free again.
    final rebound = await ServerSocket.bind('127.0.0.1', port);
    await rebound.close();
  });

  test('a moved port restarts both onto the new one', () async {
    final firstSocket = await ServerSocket.bind('127.0.0.1', 0);
    final first = firstSocket.port;
    await firstSocket.close();
    final secondSocket = await ServerSocket.bind('127.0.0.1', 0);
    final second = secondSocket.port;
    await secondSocket.close();

    settings.setRemoteAccessEnabled(true);
    settings.setRemoteRelayMode(RelayMode.local);
    settings.setLocalRelayPort(first);
    await controller.sync();
    expect(controller.service!.relay.port, first);

    settings.setLocalRelayPort(second);
    await controller.sync();

    expect(localRelay.status.boundPort, second);
    expect(controller.service!.relay.port, second);
  });

  test('a taken port surfaces as status; the host stays consistent', () async {
    final taken = await ServerSocket.bind('127.0.0.1', 0);
    addTearDown(taken.close);
    settings.setRemoteAccessEnabled(true);
    settings.setRemoteRelayMode(RelayMode.local);
    settings.setLocalRelayPort(taken.port);

    await controller.sync();

    expect(localRelay.status.state, LocalRelayState.error);
    expect(localRelay.status.error, contains('in use'));
    // The host still runs, pointed at the port the user asked for, so the
    // next sync after freeing the port needs no restart.
    expect(
      controller.service!.relay,
      Uri.parse('ws://127.0.0.1:${taken.port}'),
    );

    await taken.close();
    await controller.sync();

    expect(localRelay.status.state, LocalRelayState.running);
  });
}
