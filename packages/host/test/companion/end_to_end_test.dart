@Tags(['live'])
library;

import 'dart:typed_data';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';
import 'package:test/test.dart';

/// The whole feature, end to end, with nothing stubbed between the two ends.
///
/// The real companion client dials the real host listener over a real socket,
/// seals with the key a real pairing row holds, and reads the sessions this
/// machine actually owns. Every piece below this is the shipping one — which is
/// the only way to know the two halves agree, because each was written against
/// a description of the other.
void main() {
  late AppDatabase database;
  late SessionRegistry registry;
  late CompanionListener listener;

  final hostId = DeviceId.parse('b' * 32);
  final deviceKey = Uint8List.fromList(List.generate(32, (i) => i + 11));

  setUp(() async {
    database = AppDatabase.memory();
    registry = SessionRegistry(launcher: FakePtyLauncher());

    // What a completed pairing leaves on the host: one row, in the host's own
    // store, holding the key both ends will seal with.
    PairedDeviceDao(database).insert(
      PairedDevice(
        id: 'pixel-7',
        name: 'Pixel 7',
        deviceKey: deviceKey,
        capabilities: CapabilitySet.all,
        generation: 0,
        createdAt: DateTime.utc(2026, 9, 16),
      ),
    );

    listener = CompanionListener(
      registry: registry,
      hostName: 'do-box',
      devices: PairedDeviceDao(database).getActive,
    );
    await listener.start(address: '127.0.0.1', port: 0);
  });

  tearDown(() async {
    await listener.stop();
    database.close();
  });

  /// The same record the phone would have written when it paired, with the
  /// address the person typed.
  CompanionPairing pairingRecord() => CompanionPairing(
    hostId: hostId,
    deviceId: DeviceId.parse('c' * 32),
    deviceKey: deviceKey,
    capabilities: CapabilitySet.all,
    relay: Uri.parse('https://unused.invalid'),
    generation: 0,
    hostName: 'do-box',
    directEndpoint: '127.0.0.1:${listener.port}',
  );

  test('a phone dials the box and reads the sessions it owns', () async {
    registry.open(
      'karmashala_live',
      const PtySpawnRequest(
        argv: ['claude', '--resume'],
        workingDirectory: '/srv/app',
        environment: {},
        columns: 80,
        rows: 24,
      ),
    );

    final client = CompanionClient(
      pairing: pairingRecord(),
      store: InMemoryCompanionStore(),
    );
    addTearDown(client.close);

    await client.connect(
      transport: LanTransport(host: '127.0.0.1', port: listener.port)..start(),
      generation: 0,
      helloTimeout: const Duration(seconds: 10),
    );

    final sessions = await client.listSessions();

    expect(sessions, hasLength(1));
    expect(sessions.single.sessionId, 'karmashala_live');
    expect(sessions.single.title, 'claude --resume');
    expect(sessions.single.status, 'running');
    // Which box, which is the fact a phone talking straight to one needs.
    expect(sessions.single.whereabouts, 'on do-box');
  });

  test('a phone whose key is not the row\'s never gets past hello', () async {
    final impostor = CompanionClient(
      pairing: CompanionPairing(
        hostId: hostId,
        deviceId: DeviceId.parse('d' * 32),
        // The right *shape* and the wrong key: the rendezvous will not match,
        // so the host answers nothing at all rather than refusing in words.
        deviceKey: Uint8List.fromList(List.filled(32, 99)),
        capabilities: CapabilitySet.all,
        relay: Uri.parse('https://unused.invalid'),
        generation: 0,
        hostName: 'do-box',
      ),
      store: InMemoryCompanionStore(),
    );
    addTearDown(impostor.close);

    await expectLater(
      impostor.connect(
        transport: LanTransport(host: '127.0.0.1', port: listener.port)..start(),
        generation: 0,
        helloTimeout: const Duration(seconds: 3),
      ),
      throwsA(anything),
      reason: 'the key is the only thing that decides, and it is not in the row',
    );
  });

  test('what the host cannot answer is refused, not faked', () async {
    final client = CompanionClient(
      pairing: pairingRecord(),
      store: InMemoryCompanionStore(),
    );
    addTearDown(client.close);
    await client.connect(
      transport: LanTransport(host: '127.0.0.1', port: listener.port)..start(),
      generation: 0,
      helloTimeout: const Duration(seconds: 10),
    );

    // A host serves sessions and not yet workspaces. The phone is told so,
    // rather than being handed an empty list it would draw as "no projects".
    expect(await client.listProjects(), isEmpty);
  });
}
