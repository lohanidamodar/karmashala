/// A held desktop link someone is waiting on (round 50): after the app comes
/// back or the network changes, a resume that cannot land is ended within
/// `afterProof` so the owners redial, rather than showing "Reconnecting…"
/// for the whole grace; and a resume that fails on this network in the
/// moment the phone thaws leaves the address tried again on the next pass.
/// End to end over the server's LAN listener and in-process relays on
/// 127.0.0.1.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';
import 'package:test/test.dart';

import 'fake_bindings.dart';
import 'transport_harness.dart';

final _hostId = DeviceId.parse('11111111222222223333333344444444');
final _deviceId = DeviceId.parse('aaaaaaaabbbbbbbbccccccccdddddddd');
final _secret = Uint8List.fromList(List<int>.generate(32, (i) => 0x51 + i));

void main() {
  late AppDatabase db;
  late PairedDeviceDao dao;
  late RelayServer relay;
  late Uri relayUri;
  RemoteHostService? service;

  setUp(() async {
    db = AppDatabase.memory();
    dao = PairedDeviceDao(db);
    relay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    relayUri = Uri.parse('http://127.0.0.1:${relay.port}');
  });

  tearDown(() async {
    await service?.stop();
    service = null;
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

  RemoteTransport relayTransport(Uri relay, RendezvousId rendezvous) =>
      RelayTransport(
        endpoint: RelayTransport.endpointFor(relay, rendezvous),
        backoff: fastBackoff(),
        heartbeat: const Duration(milliseconds: 500),
      )..start();

  Future<RemoteHostService> start() async {
    dao.insert(
      PairedDevice(
        id: _deviceId.value,
        name: 'oppo',
        deviceKey: await deviceKey(),
        capabilities: CapabilitySet.of([Capability.desktopClient]),
        generation: kFirstSessionGeneration,
        createdAt: DateTime.utc(2026, 10, 8),
        relayUrl: relayUri.toString(),
      ),
    );
    final started = RemoteHostService(
      devices: dao,
      hostId: _hostId,
      bindings: FakeRemoteBindings().bindings,
      relay: relayUri,
      lanPort: 0,
      advertise: false,
      transcriptPollInterval: Duration.zero,
      relayFactory: relayTransport,
      onHostLink: (link) => link.incoming.listen(link.add),
    );
    service = started;
    await started.start();
    return started;
  }

  Future<CompanionStore> saved({String? lanHint}) async {
    final store = InMemoryCompanionStore();
    await CompanionPairing(
      hostId: _hostId,
      deviceId: _deviceId,
      deviceKey: await deviceKey(),
      capabilities: CapabilitySet.of([Capability.desktopClient]),
      relay: relayUri,
      generation: kFirstSessionGeneration,
      hostName: 'desk',
      lanHint: lanHint,
    ).save(store);
    return store;
  }

  Future<List<int>> echo(SealedHostLink link, List<int> bytes) async {
    final got = <int>[];
    final done = Completer<void>();
    final sub = link.incoming.listen((chunk) {
      got.addAll(chunk);
      if (got.length >= bytes.length && !done.isCompleted) done.complete();
    });
    link.add(Uint8List.fromList(bytes));
    await done.future.timeout(const Duration(seconds: 10));
    await sub.cancel();
    return got;
  }

  Future<void> until(bool Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('a held link that cannot resume is ended within afterProof of a '
      'return to the app, long before the grace', () async {
    await start();
    final store = await saved();
    final logs = <String>[];
    final dialer = DesktopServerDialer(
      store: store,
      timeout: const Duration(seconds: 1),
      relayFactory: relayTransport,
      resumeAfterProof: const Duration(milliseconds: 400),
      onLog: logs.add,
    );
    addTearDown(dialer.close);
    final held = <bool>[];
    final link = await dialer.dial(
      (await CompanionPairing.load(store))!,
      resumeOffered: () => true,
      onHeld: held.add,
    );
    addTearDown(() => link.close());
    expect(await echo(link, [1, 2]), [1, 2]);

    // The only route goes: the link is held, and nothing can resume it.
    await relay.close();
    await until(() => held.contains(true));

    // Nobody is looking: the grace, not afterProof, decides.
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(link.isClosed, isFalse);

    // The app comes back: within afterProof the link ends, so it is redialled.
    final returned = DateTime.now();
    dialer.proveLinks();
    await link.done.timeout(const Duration(seconds: 5));
    expect(
      DateTime.now().difference(returned),
      lessThan(const Duration(seconds: 3)),
    );
    expect(held.last, isFalse);
    expect(
      logs,
      contains(
        allOf(contains('not resumed within'), contains('retired, redialling')),
      ),
    );
  });

  test(
    'a held link that resumes in time is left alone by afterProof',
    () async {
      final host = await start();
      final store = await saved(lanHint: '10.255.255.1:${host.lanPortBound}');
      RemoteTransport? live;
      final scout = LanPathScout(
        beaconPort: await freeBeaconPort(),
        dialer: (_, _) => live = LanTransport.dial(
          host: '127.0.0.1',
          port: host.lanPortBound!,
        ),
      );
      final dialer = DesktopServerDialer(
        store: store,
        timeout: const Duration(seconds: 1),
        lanTimeout: const Duration(seconds: 1),
        relayFactory: relayTransport,
        scout: scout,
        resumeAfterProof: const Duration(milliseconds: 600),
      );
      addTearDown(dialer.close);
      final link = await dialer.dial(
        (await CompanionPairing.load(store))!,
        resumeOffered: () => true,
      );
      addTearDown(() => link.close());

      final first = live!;
      await first.close();
      dialer.proveLinks();
      await until(() => !identical(live, first) && !link.suspended);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(link.isClosed, isFalse);
      expect(await echo(link, [4, 5]), [4, 5]);
    },
  );

  test('a resume that fails on this network as the phone thaws leaves the '
      'address in the next pass: the link comes back over it', () async {
    final host = await start();
    final store = await saved(lanHint: '10.255.255.1:${host.lanPortBound}');
    // Nothing listens here: the first resume's socket, opened before the
    // phone's network is back.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final nowhere = probe.port;
    await probe.close();
    var failNext = false;
    RemoteTransport? live;
    final scout = LanPathScout(
      beaconPort: await freeBeaconPort(),
      dialer: (_, _) {
        if (failNext) {
          failNext = false;
          return LanTransport.dial(host: '127.0.0.1', port: nowhere);
        }
        return live = LanTransport.dial(
          host: '127.0.0.1',
          port: host.lanPortBound!,
        );
      },
    );
    final logs = <String>[];
    final dialer = DesktopServerDialer(
      store: store,
      timeout: const Duration(seconds: 1),
      lanTimeout: const Duration(seconds: 1),
      relayFactory: relayTransport,
      scout: scout,
      onLog: logs.add,
    );
    addTearDown(dialer.close);
    final link = await dialer.dial(
      (await CompanionPairing.load(store))!,
      resumeOffered: () => true,
    );
    addTearDown(() => link.close());
    // The relay is gone too, as it is to a server that will not answer
    // there: only this network can bring the link back.
    await relay.close();

    final first = live!;
    failNext = true;
    await first.close();
    await until(() => logs.any((l) => l.startsWith('resumed link')));
    expect(link.isClosed, isFalse);
    final hint = (await CompanionPairing.load(store))!.lanHint!;
    expect(scout.inCooldown(_hostOf(hint)), isFalse);
    expect(await echo(link, [7, 8]), [7, 8]);
  });
}

DiscoveredHost _hostOf(String hint) {
  final parsed = parseLanHint(hint)!;
  return DiscoveredHost(
    address: InternetAddress(parsed.host),
    advert: LanAdvert(port: parsed.port, tag: 'hint'),
    seenAt: DateTime.now(),
  );
}
