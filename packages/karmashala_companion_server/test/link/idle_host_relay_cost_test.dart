/// What an idle host costs its relay: one connection per listener, once.
///
/// A shared relay sends a lone socket away after its lone timeout, and the
/// host's listeners — one per paired device per generation in the window —
/// each dialled straight back. With nobody connecting, that was a fresh
/// upgrade per listener every two minutes, for ever. The host's own relay
/// factory now keeps its listeners alive with the relay heartbeat, and this
/// holds it to that with the factory it actually ships.
library;

import 'dart:typed_data';

import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';
import 'package:test/test.dart';

import 'fake_bindings.dart';

final _hostId = DeviceId.parse('11111111222222223333333344444444');
final _phone = DeviceId.parse('aaaaaaaabbbbbbbbccccccccdddddddd');
final _secret = Uint8List.fromList(List<int>.generate(32, (i) => 0x51 + i));

void main() {
  test('an idle host dials each listener once, however many lone timeouts '
      'pass', () async {
    var upgrades = 0;
    final relay = await RelayServer.bind(
      address: '127.0.0.1',
      port: 0,
      options: RelayOptions(
        loneTimeout: const Duration(milliseconds: 200),
        onLog: (line) {
          if (line.startsWith('a socket is waiting')) upgrades++;
        },
      ),
    );
    addTearDown(relay.close);
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final dao = PairedDeviceDao(db);
    dao.insert(
      PairedDevice(
        id: _phone.value,
        name: 'phone',
        deviceKey: Uint8List.fromList(
          (await deriveDeviceKey(
            pairingSecret: _secret,
            hostId: _hostId,
            deviceId: _phone,
          )).bytes,
        ),
        capabilities: CapabilitySet.all,
        generation: kFirstSessionGeneration,
        createdAt: DateTime.utc(2026, 11, 12),
        relayUrl: 'http://127.0.0.1:${relay.port}',
      ),
    );
    // No `relayFactory`: the one under test is the service's own.
    final service = RemoteHostService(
      devices: dao,
      hostId: _hostId,
      bindings: (FakeRemoteBindings()..addSession('s1')).bindings,
      relay: Uri.parse('http://127.0.0.1:${relay.port}'),
      lanPort: 0,
      advertise: false,
      transcriptPollInterval: Duration.zero,
    );
    await service.start();
    addTearDown(service.stop);

    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (relay.rendezvousCount < kHostRelayListenWindow) {
      if (DateTime.now().isAfter(deadline)) fail('the host never listened');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    // Fifteen lone timeouts, and three times the redial wait a listener
    // sent away would have taken.
    await Future<void>.delayed(const Duration(seconds: 3));

    expect(relay.rendezvousCount, kHostRelayListenWindow);
    expect(
      upgrades,
      kHostRelayListenWindow,
      reason: 'no listener was sent away, so none dialled again',
    );
  });
}
