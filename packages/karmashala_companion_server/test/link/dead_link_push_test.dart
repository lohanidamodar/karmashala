/// News is for a phone that is there.
///
/// A device's link outlives the phone: `_active` is what carries the sealed
/// channel across a reconnect, so it is deliberately NOT torn down when the
/// socket under it drops. What must not outlive the phone is the *pushing* —
/// a `session.changed` built, sealed and written for a link nobody holds is
/// work the desktop pays at its own rate of change (every attention cycle,
/// ~1.2 s), and the frame lands in a rendezvous with one socket at it, which
/// the relay buffers eight of and then hangs up on. The listener redials, the
/// next change does it again, and that is a reconnect per desktop change for
/// as long as the app runs.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala_store/database.dart';
import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_store/devices.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:test/test.dart';

import 'fake_bindings.dart';
import 'transport_harness.dart';

final _hostId = DeviceId.parse('11111111222222223333333344444444');
final _deviceId = DeviceId.parse('aaaaaaaabbbbbbbbccccccccdddddddd');
final _secret = Uint8List.fromList(List<int>.generate(32, (i) => 0x51 + i));

void main() {
  late AppDatabase db;
  late PairedDeviceDao dao;
  late FakeRemoteBindings fake;
  late RelayServer relay;
  late Uri relayUri;
  late RemoteHostService service;
  final cleanups = <Future<void> Function()>[];

  setUp(() async {
    db = AppDatabase.memory();
    dao = PairedDeviceDao(db);
    fake = FakeRemoteBindings()..addSession('s1');
    relay = await RelayServer.bind(
      address: '127.0.0.1',
      port: 0,
      options: const RelayOptions(loneTimeout: Duration.zero),
    );
    relayUri = Uri.parse('http://127.0.0.1:${relay.port}');
  });

  tearDown(() async {
    for (final cleanup in cleanups.reversed.toList()) {
      await cleanup();
    }
    cleanups.clear();
    await service.stop();
    await relay.close();
    db.close();
  });

  Future<Uint8List> deviceKey() async => Uint8List.fromList(
    (await deriveDeviceKey(
      pairingSecret: _secret,
      hostId: _hostId,
      deviceId: _deviceId,
    )).bytes,
  );

  Future<void> pairDevice() async {
    dao.insert(
      PairedDevice(
        id: _deviceId.value,
        name: 'OPPO',
        deviceKey: await deviceKey(),
        capabilities: CapabilitySet.all,
        generation: kFirstSessionGeneration,
        createdAt: DateTime.utc(2026, 8, 31),
      ),
    );
  }

  Future<void> startService() async {
    service = RemoteHostService(
      devices: dao,
      hostId: _hostId,
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
  }

  Future<CompanionClient> makeClient() async {
    final client = CompanionClient(
      pairing: CompanionPairing(
        hostId: _hostId,
        deviceId: _deviceId,
        deviceKey: await deviceKey(),
        capabilities: CapabilitySet.all,
        relay: relayUri,
        generation: kFirstSessionGeneration,
        hostName: 'TestHost',
      ),
      store: InMemoryCompanionStore(),
      requestTimeout: const Duration(seconds: 5),
      relayFactory: (relay, rendezvous) => RelayTransport(
        endpoint: RelayTransport.endpointFor(relay, rendezvous),
        backoff: fastBackoff(),
        heartbeat: const Duration(milliseconds: 500),
      )..start(),
    );
    cleanups.add(client.close);
    return client;
  }

  /// Waits until [condition] holds, or fails.
  Future<void> until(String what, bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('never $what');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// One desktop change, announced the way the attention and session-revision
  /// listeners announce one.
  Future<void> desktopChanged(int nth) async {
    fake.addSession('s1', title: 'Fix the tests ($nth)');
    await service.notifySessionsChanged();
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }

  test('a phone that left is pushed nothing, however often the desktop '
      'changes', () async {
    await pairDevice();
    await startService();

    // A real phone: hello, list, subscribe — everything that makes the host
    // consider this device worth telling things to.
    final client = await makeClient();
    await client.connect(helloTimeout: const Duration(seconds: 5));
    expect((await client.listSessions()).single.sessionId, 's1');
    await client.subscribeSession('s1');
    await until(
      'saw the link go live',
      () => service.hasLiveLink(_deviceId.value),
    );

    // And then it is gone — backgrounded, out of range, killed.
    await client.close();
    await until(
      'noticed the phone left',
      () => !service.hasLiveLink(_deviceId.value),
    );

    // Somebody is at the rendezvous — the host's own listener redialled, and
    // this is whatever the relay pairs it with next. It never speaks, so
    // nothing here has proved a phone is on the other end.
    final rendezvous = await rendezvousFor(
      await deriveDeviceKey(
        pairingSecret: _secret,
        hostId: _hostId,
        deviceId: _deviceId,
      ),
      kFirstSessionGeneration,
    );
    final pushed = <Object?>[];
    final silent = await WebSocket.connect(
      'ws://127.0.0.1:${relay.port}/v1/${rendezvous.value}',
    );
    silent.listen(pushed.add, onError: (Object _) {});
    cleanups.add(() => silent.close());
    await Future<void>.delayed(const Duration(milliseconds: 400));

    for (var i = 0; i < 10; i++) {
      await desktopChanged(i);
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(
      pushed,
      isEmpty,
      reason:
          'the desktop sealed and sent ${pushed.length} frames to a link no '
          'phone is holding — one per change, for ever',
    );
  });

  test('a phone that is there hears every change', () async {
    await pairDevice();
    await startService();
    final client = await makeClient();
    await client.connect(helloTimeout: const Duration(seconds: 5));
    final events = ItemQueue<CompanionEvent>(
      client.events.where((event) => event is SessionChangedEvent),
    );
    cleanups.add(events.cancel);
    await client.listSessions();
    await client.subscribeSession('s1');

    // `sessions.subscribe` answers with the snapshot as it stands; the change
    // is what comes after it.
    expect(
      (await events.next as SessionChangedEvent).snapshot.title,
      'Fix the tests',
    );

    await desktopChanged(1);
    final changed = await events.next as SessionChangedEvent;
    expect(changed.snapshot.sessionId, 's1');
    expect(changed.snapshot.title, 'Fix the tests (1)');
  });
}
