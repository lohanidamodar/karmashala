/// The embedded relay, end to end below the UI: turning it on brings it up
/// and tells the server's companion its LAN URL, turning it off tears it down
/// and says so. Loopback only — nothing binds 0.0.0.0.
library;

import 'dart:io';
import '../../../support/memory_server_config.dart';

import 'package:karmashala/src/features/remote/application/relay_prefs.dart';
import 'package:karmashala/src/features/remote/application/remote_access_controller.dart';
import 'package:karmashala/src/features/remote/application/host_companion_link.dart';
import 'package:karmashala/src/features/remote/application/host_companion_providers.dart';
import 'package:karmashala/src/features/remote/relay_local/local_relay_providers.dart';
import 'package:karmashala/src/features/remote/relay_local/local_relay_service.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_data_server.dart';
import '../../../support/fake_host_lifecycle.dart';

void main() {
  late FakeHostLifecycle host;
  late LocalRelayService localRelay;
  late ProviderContainer container;
  late RemoteAccessController controller;
  late SettingsController settings;
  late RelayPrefsController prefs;

  /// Where the server was last told the embedded relay listens.
  Uri? relayTold() {
    final url = host.companionAttaches.last;
    return url == null ? null : Uri.parse(url);
  }

  setUp(() async {
    host = FakeHostLifecycle();
    localRelay = LocalRelayService(
      bindAddress: '127.0.0.1',
      interfaces: () async => [(name: 'lo', ip: '127.0.0.1')],
    );
    final link = HostCompanionLink(
      deviceById: (_) async => null,
    );
    container = ProviderContainer(
      overrides: [
        await FakeDataServer().override(),
        serverConfigIn(MemoryServerConfigSource()),
        companionAtHostProvider.overrideWithValue(true),
        hostCompanionLinkProvider.overrideWithValue(link),
        localRelayServiceProvider.overrideWithValue(localRelay),
        remoteAccessControllerProvider.overrideWith(RemoteAccessController.new),
      ],
    );
    controller = container.read(remoteAccessControllerProvider);
    settings = container.read(settingsControllerProvider.notifier);
    prefs = container.read(relayPrefsProvider.notifier);
    link.attached((await host.open())!);
  });

  tearDown(() async {
    await controller.shutdown();
    await localRelay.stop();
    container.dispose();
  });

  test('turning the local relay on starts it and tells the server', () async {
    setRemoteAccessNow(container, enabled: true);
    settings.setLocalRelayPort(0);
    prefs.setLocalEnabled(true);

    await controller.sync();

    expect(localRelay.isRunning, isTrue);
    final port = localRelay.status.boundPort!;
    expect(relayTold(), Uri.parse('ws://127.0.0.1:$port'));
    // The relay the QR will name is genuinely serving.
    final client = HttpClient();
    final response = await (await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/healthz'),
    )).close();
    expect(response.statusCode, 200);
    client.close(force: true);
  });

  test('turning the local relay off stops it and tells the server', () async {
    setRemoteAccessNow(container, enabled: true);
    settings.setLocalRelayPort(0);
    prefs.setLocalEnabled(true);
    setRemoteAccessNow(container, hostedEnabled: true);
    await controller.sync();
    expect(localRelay.isRunning, isTrue);

    prefs.setLocalEnabled(false);
    await controller.sync();

    expect(localRelay.status.state, LocalRelayState.stopped);
    expect(relayTold(), isNull);
  });

  test('turning the hosted relay off leaves the local one serving', () async {
    setRemoteAccessNow(container, enabled: true);
    settings.setLocalRelayPort(0);
    prefs.setLocalEnabled(true);
    setRemoteAccessNow(container, hostedEnabled: true);
    await controller.sync();

    setRemoteAccessNow(container, hostedEnabled: false);
    await controller.sync();

    expect(localRelay.isRunning, isTrue);
    expect(relayTold(), isNotNull);
  });

  test(
    'disabling remote access stops the relay and tells the server',
    () async {
      setRemoteAccessNow(container, enabled: true);
      settings.setLocalRelayPort(0);
      prefs.setLocalEnabled(true);
      await controller.sync();
      final port = localRelay.status.boundPort!;

      setRemoteAccessNow(container, enabled: false);
      await controller.sync();

      expect(localRelay.status.state, LocalRelayState.stopped);
      expect(relayTold(), isNull);
      // The port really is free again.
      final rebound = await ServerSocket.bind('127.0.0.1', port);
      await rebound.close();
    },
  );

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
    expect(relayTold()!.port, first);

    settings.setLocalRelayPort(second);
    await controller.sync();

    expect(localRelay.status.boundPort, second);
    expect(relayTold()!.port, second);
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
    expect(relayTold(), isNull);

    await taken.close();
    await controller.sync();

    expect(localRelay.status.state, LocalRelayState.running);
    expect(relayTold(), isNotNull);
  });
}
