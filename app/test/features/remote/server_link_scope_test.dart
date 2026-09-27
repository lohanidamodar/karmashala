/// "Run local terminals in the session host" decides only where panes run:
/// with it off, the app's link to this machine's server — pairing, attention
/// news, the embedded relay's URL, the lifecycle feed — is the same as on.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/remote/application/host_companion_link.dart';
import 'package:karmashala/src/features/remote/application/host_companion_providers.dart';
import 'package:karmashala/src/features/remote/application/relay_prefs.dart';
import 'package:karmashala/src/features/remote/application/remote_access_controller.dart';
import 'package:karmashala/src/features/remote/application/remote_access_settings.dart';
import 'package:karmashala/src/features/remote/relay_local/local_relay_providers.dart';
import 'package:karmashala/src/features/remote/relay_local/local_relay_service.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/terminal/application/local_host_providers.dart';
import 'package:karmashala_host/host_paths.dart';
import 'package:karmashala_host/lifecycle_client.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_terminal_runtime/host_link.dart';

import '../../support/fake_data_server.dart';
import '../../support/fake_host_lifecycle.dart';
import '../../support/memory_server_config.dart';

void main() {
  late Directory home;

  setUp(() => home = Directory.systemTemp.createTempSync('ks-scope'));
  tearDown(() => home.deleteSync(recursive: true));

  LocalHostSessionAccess access() =>
      LocalHostSessionAccess(paths: HostPaths(Directory('${home.path}/host')));

  group('the gates', () {
    test('with local terminals in the app, the server link is still there', () {
      final container = ProviderContainer(
        overrides: [
          localHostSessionAccessProvider.overrideWithValue(access()),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(companionAtHostProvider), isTrue);
      expect(container.read(hostLifecycleSourceProvider), isNotNull);
      expect(container.read(hostedSessionEnderProvider), isNotNull);
      expect(
        container.read(serverConfigSourceProvider),
        isA<HostServerConfigSource>(),
      );
    });

    test('with no local server there is no link to it', () {
      final container = ProviderContainer(
        overrides: [
          localHostSessionAccessProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(companionAtHostProvider), isFalse);
      expect(container.read(hostLifecycleSourceProvider), isNull);
      expect(container.read(hostedSessionEnderProvider), isNull);
    });
  });

  group('with local terminals in the app', () {
    late FakeHostLifecycle host;
    late LocalRelayService localRelay;
    late ProviderContainer container;
    late RemoteAccessController controller;

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
          localHostSessionAccessProvider.overrideWithValue(access()),
          hostCompanionLinkProvider.overrideWithValue(link),
          localRelayServiceProvider.overrideWithValue(localRelay),
          remoteAccessControllerProvider.overrideWith(
            RemoteAccessController.new,
          ),
        ],
      );
      controller = container.read(remoteAccessControllerProvider);
      link.attached((await host.open())!);
    });

    tearDown(() async {
      await controller.shutdown();
      await localRelay.stop();
      container.dispose();
    });

    test('pairing from Settings goes through the server', () async {
      final payload = await PairingPayload.generateWithCode(
        relay: Uri.parse('wss://relay.example.com'),
        hostId: DeviceId.parse('11111111222222223333333344444444'),
        capabilities: CapabilitySet.all,
      );
      host.answerPairing = (requestId) => PairedMessage(
        requestId: requestId,
        code: 'CODE',
        expiresAt: DateTime.utc(2026, 9, 25, 13),
        payload: payload.encode(),
      );
      setRemoteAccessNow(container, enabled: true);

      final pairing = await controller.beginPairing(
        capabilities: CapabilitySet.all,
        relay: Uri.parse('wss://relay.example.com'),
      );

      expect(pairing.payload.encode(), payload.encode());
      expect(host.pairings.single.relay, 'wss://relay.example.com');
    });

    test('the embedded relay\'s URL is told to the server', () async {
      setRemoteAccessNow(container, enabled: true);
      container.read(settingsControllerProvider.notifier).setLocalRelayPort(0);
      container.read(relayPrefsProvider.notifier).setLocalEnabled(true);

      await controller.sync();

      final port = localRelay.status.boundPort!;
      expect(host.companionAttaches.last, 'ws://127.0.0.1:$port');
    });
  });
}
