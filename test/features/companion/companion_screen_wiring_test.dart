/// One companion screen rendering REAL host data through the real gateway —
/// proof the fake is not load-bearing anywhere between pixel and protocol.
library;

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala/src/features/companion/client/secure_companion_store.dart';
import 'package:karmashala_companion/screens.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala/src/features/remote/application/remote_host_service.dart';
import 'package:karmashala/src/features/remote/data/paired_device_dao.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:flutter_test/flutter_test.dart';

import '../remote/fake_bindings.dart';
import '../remote/transport_harness.dart';
import 'companion_test_support.dart';

void main() {
  testWidgets('the session list renders the host\'s real sessions through '
      'the real gateway', (tester) async {
    late AppDatabase db;
    late RemoteHostService service;
    late RelayServer relay;
    late RemoteCompanionGateway gateway;

    // Everything real-async — sockets, the relay, pairing — runs inside
    // runAsync; the widget pumps stay in the test zone.
    await tester.runAsync(() async {
      db = AppDatabase.memory();
      final dao = PairedDeviceDao(db);
      final fake = FakeRemoteBindings()..addSession('s1');
      relay = await RelayServer.bind(address: '127.0.0.1', port: 0);
      final relayUri = Uri.parse('http://127.0.0.1:${relay.port}');
      service = RemoteHostService(
        devices: dao,
        hostId: DeviceId.parse('11111111222222223333333344444444'),
        bindings: fake.bindings,
        relay: relayUri,
        lanPort: 0,
        advertise: false,
        transcriptPollInterval: Duration.zero,
        relayFactory: (relay, rendezvous) => RelayTransport(
          endpoint: RelayTransport.endpointFor(relay, rendezvous),
          backoff: fastBackoff(),
          heartbeat: const Duration(milliseconds: 500),
        )..start(),
      );
      await service.start();

      // Loop 83's last-resort relay is the phone's configured one, which
      // defaults to the public PopupBits relay — point it here instead.
      final disk = <String, String>{
        RemoteCompanionGateway.kPairingRelayStoreKey: relayUri.toString(),
      };
      gateway = RemoteCompanionGateway(
        store: SecureCompanionStore.withBackend(
          read: (key) async => disk[key],
          write: (key, value) async => disk[key] = value,
          delete: (key) async => disk.remove(key),
        ),
        relayFactory: (relay, rendezvous) => RelayTransport(
          endpoint: RelayTransport.endpointFor(relay, rendezvous),
          backoff: fastBackoff(),
          heartbeat: const Duration(milliseconds: 500),
        )..start(),
        requestTimeout: const Duration(seconds: 2),
        helloTimeout: const Duration(seconds: 2),
        reconnectBackoff: fastBackoff(),
      );

      final session = await service.beginPairing(
        capabilities: CapabilitySet.all,
      );
      await gateway.pairWithQr(session.payload.encode());
      await session.done;
      await gateway.linkStates
          .firstWhere((state) => state == CompanionLinkState.connected)
          .timeout(const Duration(seconds: 60));
      // Let the post-connect refresh land so the list has real data to show.
      final first = await gateway
          .watchSessions()
          .firstWhere((list) => list.isNotEmpty)
          .timeout(const Duration(seconds: 60));
      expect(first.single.title, 'Fix the tests');
    });

    try {
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const SessionListScreen(),
      );
      // The stream's values arrive from the real-async zone; pump until the
      // desktop card materialises.
      for (var i = 0; i < 100 && !tester.any(find.byType(SessionCard)); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }

      // The desktop's own card, fed by the host through the real protocol.
      expect(find.byType(SessionCard), findsOneWidget);
      expect(find.text('Fix the tests'), findsOneWidget);
      expect(find.textContaining('No sessions'), findsNothing);
    } finally {
      await tester.runAsync(() async {
        await gateway.close();
        await service.stop();
        await relay.close();
        db.close();
      });
    }
  });
}
