/// The two relay switches, end to end below the UI: turning the local relay
/// on brings the embedded server up and points the host at its LAN URL,
/// turning it off tears it down — and the hosted relay is a separate switch
/// that neither move touches. Loopback only — nothing binds 0.0.0.0.
library;

import 'dart:io';
import '../../../support/memory_server_config.dart';

import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/remote/application/relay_prefs.dart';
import 'package:karmashala/src/features/remote/application/remote_access_controller.dart';
import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_store/devices.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala/src/features/remote/relay_local/local_relay_providers.dart';
import 'package:karmashala/src/features/remote/relay_local/local_relay_service.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fake_bindings.dart';

void main() {
  late AppDatabase db;
  late LocalRelayService localRelay;
  late ProviderContainer container;
  late RemoteAccessController controller;
  late SettingsController settings;
  late RelayPrefsController prefs;

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
    prefs = container.read(relayPrefsProvider.notifier);
  });

  tearDown(() async {
    await controller.shutdown();
    await localRelay.stop();
    container.dispose();
    db.close();
  });

  test('turning the local relay on starts it and the host serves it', () async {
    setRemoteAccessNow(container, enabled: true);
    settings.setLocalRelayPort(0);
    prefs.setLocalEnabled(true);

    await controller.sync();

    expect(localRelay.isRunning, isTrue);
    final port = localRelay.status.boundPort!;
    expect(controller.isRunning, isTrue);
    expect(
      controller.service!.localRelayUrl,
      Uri.parse('ws://127.0.0.1:$port'),
    );
    // The relay the QR will name is genuinely serving.
    final client = HttpClient();
    final response = await (await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/healthz'),
    )).close();
    expect(response.statusCode, 200);
    client.close(force: true);
  });

  test('both switches on: both relays are served at once', () async {
    setRemoteAccessNow(container, enabled: true);
    setRemoteAccessNow(container, relayUrl: 'wss://relay.example.com');
    settings.setLocalRelayPort(0);
    prefs.setLocalEnabled(true);
    setRemoteAccessNow(container, hostedEnabled: true);

    await controller.sync();

    expect(localRelay.isRunning, isTrue);
    expect(controller.service!.hostedEnabled, isTrue);
    expect(controller.service!.localRelayUrl, isNotNull);
    expect(controller.service!.relay, Uri.parse('wss://relay.example.com'));
  });

  test(
    'turning the local relay off stops it and leaves hosted alone',
    () async {
      setRemoteAccessNow(container, enabled: true);
      settings.setLocalRelayPort(0);
      prefs.setLocalEnabled(true);
      setRemoteAccessNow(container, hostedEnabled: true);
      await controller.sync();
      final service = controller.service;
      expect(localRelay.isRunning, isTrue);

      prefs.setLocalEnabled(false);
      await controller.sync();

      expect(localRelay.status.state, LocalRelayState.stopped);
      expect(controller.service!.localRelayUrl, isNull);
      expect(controller.service!.hostedEnabled, isTrue);
      expect(
        controller.service,
        same(service),
        reason: 'a relay switch parks devices; it never restarts the host',
      );
    },
  );

  test('turning the hosted relay off leaves the local one serving', () async {
    setRemoteAccessNow(container, enabled: true);
    settings.setLocalRelayPort(0);
    prefs.setLocalEnabled(true);
    setRemoteAccessNow(container, hostedEnabled: true);
    await controller.sync();

    setRemoteAccessNow(container, hostedEnabled: false);
    await controller.sync();

    expect(controller.service!.hostedEnabled, isFalse);
    expect(localRelay.isRunning, isTrue);
    expect(controller.service!.localRelayUrl, isNotNull);
  });

  test('neither relay: the host still runs for direct LAN links', () async {
    setRemoteAccessNow(container, enabled: true);
    prefs.setLocalEnabled(false);
    setRemoteAccessNow(container, hostedEnabled: false);

    await controller.sync();

    expect(localRelay.status.state, LocalRelayState.stopped);
    expect(controller.isRunning, isTrue);
    expect(controller.service!.localRelayUrl, isNull);
    expect(controller.service!.hostedEnabled, isFalse);
    expect(controller.service!.lanPortBound, isNotNull);
  });

  test('disabling remote access stops relay and host together', () async {
    setRemoteAccessNow(container, enabled: true);
    settings.setLocalRelayPort(0);
    prefs.setLocalEnabled(true);
    await controller.sync();
    final port = localRelay.status.boundPort!;

    setRemoteAccessNow(container, enabled: false);
    await controller.sync();

    expect(controller.service, isNull);
    expect(localRelay.status.state, LocalRelayState.stopped);
    // The port really is free again.
    final rebound = await ServerSocket.bind('127.0.0.1', port);
    await rebound.close();
  });

  test('a moved port restarts the relay onto the new one', () async {
    final firstSocket = await ServerSocket.bind('127.0.0.1', 0);
    final first = firstSocket.port;
    await firstSocket.close();
    final secondSocket = await ServerSocket.bind('127.0.0.1', 0);
    final second = secondSocket.port;
    await secondSocket.close();

    setRemoteAccessNow(container, enabled: true);
    settings.setLocalRelayPort(first);
    prefs.setLocalEnabled(true);
    await controller.sync();
    expect(controller.service!.localRelayUrl!.port, first);

    settings.setLocalRelayPort(second);
    await controller.sync();

    expect(localRelay.status.boundPort, second);
    expect(controller.service!.localRelayUrl!.port, second);
  });

  test('a taken port surfaces as status, and heals on the next sync', () async {
    final taken = await ServerSocket.bind('127.0.0.1', 0);
    addTearDown(taken.close);
    setRemoteAccessNow(container, enabled: true);
    settings.setLocalRelayPort(taken.port);
    prefs.setLocalEnabled(true);

    await controller.sync();

    expect(localRelay.status.state, LocalRelayState.error);
    expect(localRelay.status.error, contains('in use'));
    // A relay that did not bind is not offered: local devices park rather
    // than dialling an address nothing answers on.
    expect(controller.service!.localRelayUrl, isNull);

    await taken.close();
    await controller.sync();

    expect(localRelay.status.state, LocalRelayState.running);
    expect(controller.service!.localRelayUrl, isNotNull);
  });
}
