/// The owner's phone, on the day it said "connected but it says connecting
/// again and cannot access session yet".
///
/// Both ends were healthy and neither could talk to the other. The desktop
/// held its rendezvous and logged `paired` every time the phone showed up; the
/// phone logged `no host at generation 2/3/4` and then, once it did get in,
/// `subscribe <id> failed: the host did not answer` — one every fifteen
/// seconds, for ever.
///
/// Everything for one device is serialised on `_DeviceRuntime._chain`, and the
/// transcript poll timer appended a whole per-session sweep to it every two
/// seconds without ever asking whether the last one had finished. On a desktop
/// with a dozen watched sessions a sweep takes longer than two seconds, so the
/// queue grew faster than it drained — for ever. The phone's frames went to
/// the back of it: its `session.subscribe` timed out, and so did the
/// `LinkHello` that would have proved the link at all.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/remote/application/remote_host_service.dart';
import 'package:karmashala/src/features/remote/client/companion_client.dart';
import 'package:karmashala/src/features/remote/client/companion_store.dart';
import 'package:karmashala/src/features/remote/data/paired_device_dao.dart';
import 'package:karmashala/src/features/remote/domain/paired_device.dart';
import 'package:karmashala/src/features/remote/pairing/pairing_payload.dart';
import 'package:karmashala/src/features/remote/protocol.dart';
import 'package:karmashala/src/features/remote/transport/key_schedule.dart';
import 'package:karmashala/src/features/remote/transport/relay_transport.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bindings.dart';
import 'transport_harness.dart';

final _hostId = DeviceId.parse('11111111222222223333333344444444');
final _phone = DeviceId.parse('aaaaaaaabbbbbbbbccccccccdddddddd');
final _secret = Uint8List.fromList(List<int>.generate(32, (i) => 0x51 + i));

/// What the owner's desktop was holding: enough watched sessions that reading
/// every transcript takes longer than the interval between polls.
const int _sessionCount = 8;
const Duration _pollInterval = Duration(milliseconds: 100);
const Duration _transcriptCost = Duration(milliseconds: 120);

void main() {
  late AppDatabase db;
  late PairedDeviceDao dao;
  late FakeRemoteBindings fake;
  late RelayServer relay;
  late Uri relayUri;
  RemoteHostService? service;
  final cleanups = <Future<void> Function()>[];

  setUp(() async {
    db = AppDatabase.memory();
    dao = PairedDeviceDao(db);
    fake = FakeRemoteBindings();
    for (var i = 0; i < _sessionCount; i++) {
      fake.addSession('s$i');
    }
    relay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    relayUri = Uri.parse('http://127.0.0.1:${relay.port}');
  });

  tearDown(() async {
    fake.transcriptCost = Duration.zero;
    for (final cleanup in cleanups.reversed.toList()) {
      await cleanup();
    }
    cleanups.clear();
    await service?.stop();
    service = null;
    await relay.close();
    db.close();
  });

  Future<Uint8List> keyFor(DeviceId deviceId) async => Uint8List.fromList(
    (await deriveDeviceKey(
      pairingSecret: _secret,
      hostId: _hostId,
      deviceId: deviceId,
    )).bytes,
  );

  Future<void> startService({Duration pollInterval = _pollInterval}) async {
    dao.insert(
      PairedDevice(
        id: _phone.value,
        name: 'phone',
        deviceKey: await keyFor(_phone),
        capabilities: CapabilitySet.all,
        generation: kFirstSessionGeneration,
        createdAt: DateTime.utc(2026, 9),
        relayUrl: 'local',
      ),
    );
    final started = service = RemoteHostService(
      devices: dao,
      hostId: _hostId,
      bindings: fake.bindings,
      relay: relayUri,
      localRelayUrl: relayUri,
      hostedEnabled: false,
      lanPort: 0,
      advertise: false,
      transcriptPollInterval: pollInterval,
      relayFactory: (relay, rendezvous) => RelayTransport(
        endpoint: RelayTransport.endpointFor(relay, rendezvous),
        backoff: fastBackoff(),
        heartbeat: const Duration(milliseconds: 500),
      )..start(),
    );
    await started.start();
  }

  Future<CompanionClient> connectedPhone() async {
    final client = CompanionClient(
      pairing: CompanionPairing(
        hostId: _hostId,
        deviceId: _phone,
        deviceKey: await keyFor(_phone),
        capabilities: CapabilitySet.all,
        relay: relayUri,
        generation: dao.getById(_phone.value)!.generation,
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
    await client.connect(helloTimeout: const Duration(seconds: 5));
    return client;
  }

  test('a desktop whose transcript sweep is slower than its poll interval '
      'still answers its phone', timeout: const Timeout(Duration(minutes: 2)),
      () async {
    await startService();
    final client = await connectedPhone();

    // Exactly what the phone does on every connect: subscribe to every session
    // the desktop listed. That is what makes each sweep expensive, and it is
    // not something the phone can be asked to stop doing.
    fake.transcriptCost = _transcriptCost;
    for (var i = 0; i < _sessionCount; i++) {
      await client.subscribeSession('s$i');
    }

    // Let the poll timer run for many multiples of its own interval. Whatever
    // it has queued behind itself by now, a request the user just made has to
    // be answered — a desktop that is up and holding this link is not allowed
    // to be silent on it.
    await Future<void>.delayed(const Duration(seconds: 3));

    final asked = DateTime.now();
    final rows = await client.listSessionRows();
    final took = DateTime.now().difference(asked);

    expect(rows, hasLength(_sessionCount));
    expect(
      took,
      lessThan(const Duration(seconds: 2)),
      reason: 'the phone waited ${took.inMilliseconds}ms for one request: the '
          'poll timer has queued more work than the chain can drain, and every '
          'frame the user sends is behind it',
    );
  });

  test('a tick that arrives while a sweep is running is swallowed, not '
      'stacked behind it', timeout: const Timeout(Duration(minutes: 2)),
      () async {
    // The timer off, so the only ticks are the ones this test delivers.
    await startService(pollInterval: Duration.zero);
    final client = await connectedPhone();
    for (var i = 0; i < _sessionCount; i++) {
      await client.subscribeSession('s$i');
    }
    fake.transcriptCost = _transcriptCost;
    fake.transcriptReads = 0;

    // One sweep starts; two more ticks arrive long before it can finish, which
    // is exactly what a 100ms timer does to a sweep that takes a second.
    final sweep = service!.pollTranscriptsNow();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await service!.pollTranscriptsNow();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await service!.pollTranscriptsNow();
    await sweep;

    expect(
      fake.transcriptReads,
      _sessionCount,
      reason: 'three ticks did ${fake.transcriptReads} transcript reads: a '
          'sweep already in flight reads the same sessions from the same '
          'state, so a tick on top of it is work the chain can never repay',
    );
  });

  test('a burst of session changes is answered by one pass, not by a queue '
      'the phone then sits behind', timeout: const Timeout(Duration(minutes: 2)),
      () async {
    await startService(pollInterval: Duration.zero);
    final client = await connectedPhone();
    for (var i = 0; i < _sessionCount; i++) {
      await client.subscribeSession('s$i');
    }
    // The stage lookup is the expensive half of a snapshot push, and it is
    // what a desktop with live agents pays on every change.
    fake.stageCost = _transcriptCost;
    fake.stageReads = 0;

    // Six sessions all move at once — which on a desktop watching six agents
    // is an ordinary second.
    final first = service!.notifySessionsChanged();
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      unawaited(service!.notifySessionsChanged());
    }
    await first;
    await Future<void>.delayed(const Duration(seconds: 2));

    expect(
      fake.stageReads,
      lessThanOrEqualTo(_sessionCount * 2),
      reason: 'six notifications did ${fake.stageReads} stage lookups: a pass '
          'that sends only what moved says everything a queue of them would, '
          'and the queue is what starves the link',
    );
    final asked = DateTime.now();
    expect((await client.listSessionRows()), hasLength(_sessionCount));
    expect(DateTime.now().difference(asked), lessThan(
      const Duration(seconds: 2),
    ));
  });
}
