import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/companion/device_links.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';
import 'package:test/test.dart';

/// A phone bumps its generation after every link that answered, and dials a box
/// once, at that number. So the host has to move with it — a row that stayed
/// where pairing left it answers the first link and no other.
void main() {
  late AppDatabase database;
  late PairedDeviceDao devices;
  late CompanionListener listener;
  late InMemoryCompanionStore phoneStore;

  final deviceKey = Uint8List.fromList(List.generate(32, (i) => i + 21));

  setUp(() async {
    database = AppDatabase.memory();
    devices = PairedDeviceDao(database);
    devices.insert(
      PairedDevice(
        id: 'pixel-7',
        name: 'Pixel 7',
        deviceKey: deviceKey,
        capabilities: CapabilitySet.all,
        generation: 1,
        createdAt: DateTime.utc(2026, 9, 17),
      ),
    );
    listener = CompanionListener(
      registry: SessionRegistry(launcher: FakePtyLauncher()),
      hostName: 'do-box',
      devices: devices.getActive,
      onGeneration: devices.updateGeneration,
    );
    await listener.start(address: '127.0.0.1', port: 0);
    phoneStore = InMemoryCompanionStore();
  });

  tearDown(() async {
    await listener.stop();
    database.close();
  });

  CompanionPairing record(int generation) => CompanionPairing(
    hostId: DeviceId.parse('b' * 32),
    deviceId: DeviceId.parse('c' * 32),
    deviceKey: deviceKey,
    capabilities: CapabilitySet.all,
    relay: Uri.parse('https://unused.invalid'),
    generation: generation,
    hostName: 'do-box',
    directEndpoint: '127.0.0.1:${listener.port}',
  );

  /// One link the way `_dialDirect` makes it: the record's own generation, one
  /// attempt. Answers the generation the phone will dial next.
  Future<int> link(
    int generation, {
    Duration wait = const Duration(seconds: 5),
  }) async {
    final client = CompanionClient(
      pairing: record(generation),
      store: phoneStore,
    );
    try {
      await client.connect(
        transport: LanTransport(host: '127.0.0.1', port: listener.port)
          ..start(),
        generation: generation,
        helloTimeout: wait,
      );
      await client.listSessions();
      return client.pairing.generation;
    } finally {
      await client.close();
    }
  }

  test('a phone that comes back is served again', () async {
    final next = await link(1);
    expect(next, 2, reason: 'the phone bumps after a link that answered');

    // The second link of a phone's life. Before the window this was "a
    // rendezvous nobody here answers", for ever.
    expect(await link(next), 3);
    expect(await link(3), 4);
  });

  test(
    'the row moves forward, so a host restart still finds the phone',
    () async {
      await link(1);
      await link(2);

      expect(devices.getById('pixel-7')!.generation, 3);
    },
  );

  test('a generation already served is never answered again', () async {
    await link(1);
    await link(2);

    // Somebody replaying a rendezvous they watched go by. A fresh link would
    // open a fresh replay window, so the only safe answer is none.
    await expectLater(
      link(1, wait: const Duration(seconds: 2)),
      throwsA(anything),
    );
    expect(
      devices.getById('pixel-7')!.generation,
      3,
      reason: 'never walked back',
    );
  });

  test('a phone that pairs again starts its count over', () async {
    await link(1);
    await link(2);

    // Same phone, new key, generation back at one — what a re-pair writes. The
    // old key's count must not be held against it.
    final fresh = Uint8List.fromList(List.generate(32, (i) => i + 77));
    devices.insert(
      PairedDevice(
        id: 'pixel-7',
        name: 'Pixel 7',
        deviceKey: fresh,
        capabilities: CapabilitySet.all,
        generation: 1,
        createdAt: DateTime.utc(2026, 9, 17),
      ),
    );

    final row = devices.getById('pixel-7')!;
    expect(listener.links.floorOf(row), 1);
    final match = await listener.links.match(
      (await rendezvousFor(SecretKeyData(fresh), 1)).value,
    );
    expect(match?.generation, 1);
  });

  test('a phone whose counter ran ahead is found inside the window', () async {
    expect(
      await link(1 + kHostGenerationWindow - 1),
      1 + kHostGenerationWindow,
    );
  });

  test('and one beyond it is not', () async {
    await expectLater(
      link(1 + kHostGenerationWindow, wait: const Duration(seconds: 2)),
      throwsA(anything),
    );
  });
}
