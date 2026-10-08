/// A suspended desktop link whose retain window overflows (round 50): the
/// server ends it, but keeps its generation answering for the grace, so a
/// client coming back to resume is refused and redials at once — before,
/// the generation was retired silently and the client heard nothing until
/// its own two-minute grace ran out. End to end over the server's LAN
/// listener on 127.0.0.1.
library;

import 'dart:async';
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
final _secret = Uint8List.fromList(List<int>.generate(32, (i) => 0x61 + i));

void main() {
  late AppDatabase db;
  late PairedDeviceDao dao;
  late RelayServer relay;
  late Uri relayUri;
  RemoteHostService? service;
  late List<String> serverLogs;
  late List<SealedHostLink> served;

  setUp(() async {
    db = AppDatabase.memory();
    dao = PairedDeviceDao(db);
    relay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    relayUri = Uri.parse('http://127.0.0.1:${relay.port}');
    serverLogs = [];
    served = [];
    addTearDown(() => printOnFailure('server log:\n${serverLogs.join('\n')}'));
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

  Future<RemoteHostService> start({
    Duration linkResumeGrace = kHostLinkResumeGrace,
  }) async {
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
      linkResumeGrace: linkResumeGrace,
      onLog: serverLogs.add,
      onHostLink: (link) {
        served.add(link);
        link.incoming.listen(link.add);
      },
    );
    service = started;
    await started.start();
    return started;
  }

  /// A client on the server's LAN listener whose network can be cut: while
  /// [ClientNet.up] is false every socket it opens finds nobody.
  Future<(DesktopServerDialer, CompanionStore, ClientNet, List<String>)> client(
    RemoteHostService host,
  ) async {
    final store = InMemoryCompanionStore();
    await CompanionPairing(
      hostId: _hostId,
      deviceId: _deviceId,
      deviceKey: await deviceKey(),
      capabilities: CapabilitySet.of([Capability.desktopClient]),
      relay: relayUri,
      generation: kFirstSessionGeneration,
      hostName: 'desk',
      // A loopback hint is refused by design; the dialer below reaches the
      // server on loopback whatever the hint names.
      lanHint: '10.255.255.1:${host.lanPortBound}',
    ).save(store);
    final net = ClientNet();
    final logs = <String>[];
    addTearDown(() => printOnFailure('client log:\n${logs.join('\n')}'));
    final scout = LanPathScout(
      beaconPort: await freeBeaconPort(),
      dialer: (_, _) => net.live = LanTransport.dial(
        host: '127.0.0.1',
        port: net.up ? host.lanPortBound! : 1,
      ),
    );
    final dialer = DesktopServerDialer(
      store: store,
      timeout: const Duration(seconds: 1),
      lanTimeout: const Duration(seconds: 1),
      relayFactory: relayTransport,
      scout: scout,
      onLog: logs.add,
    );
    addTearDown(dialer.close);
    // The relay is not where this link lives: only the LAN brings it back.
    await relay.close();
    return (dialer, store, net, logs);
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

  Future<void> until(bool Function() done, {int seconds = 15}) async {
    final deadline = DateTime.now().add(Duration(seconds: seconds));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// Cuts the client's network, waits for the server to hold the link, then
  /// sends more than its retain window takes: a busy session while the phone
  /// is frozen. The server ends the link.
  Future<void> overflowWhileAway(ClientNet net) async {
    net.up = false;
    await net.live!.close();
    final host = served.last;
    // A busy session finds the dead socket by writing to it.
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!host.suspended) {
      if (DateTime.now().isAfter(deadline)) fail('never suspended');
      host.add(Uint8List.fromList([0]));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    // One frame each: what is added in one turn is sealed as one.
    for (var i = 0; i < kHostLinkRetainFrames + 10 && !host.isClosed; i++) {
      host.add(Uint8List.fromList([i & 0xff]));
      await host.flush();
    }
    await until(() => host.isClosed);
  }

  test('a resume after the window overflowed is refused at once, and the '
      'redial lands on the next generation', () async {
    final host = await start();
    final (dialer, store, net, logs) = await client(host);
    final link = await dialer.dial(
      (await CompanionPairing.load(store))!,
      resumeOffered: () => true,
    );
    final generation = dao.getById(_deviceId.value)!.generation;

    await overflowWhileAway(net);
    await until(
      () => serverLogs.any(
        (l) =>
            l.contains('ended while suspended') &&
            l.contains('the resume window overflowed'),
      ),
    );

    // The phone comes back: its next pass is refused, well inside the grace.
    final back = DateTime.now();
    net.up = true;
    await link.done.timeout(const Duration(seconds: 10));
    expect(
      DateTime.now().difference(back),
      lessThan(const Duration(seconds: 8)),
    );
    expect(link.closeReason, contains(kLinkEndedWhileSuspended));
    expect(logs, contains(contains('refused the resume')));
    expect(serverLogs, contains(contains('refused a link.resume')));
    expect(serverLogs, isNot(contains('lan hello for an unknown rendezvous')));

    // What the owners do next: a fresh dial, on a fresh generation.
    final again = await dialer.dial((await CompanionPairing.load(store))!);
    addTearDown(() => again.close());
    expect(await echo(again, [1, 2, 3]), [1, 2, 3]);
    expect(dao.getById(_deviceId.value)!.generation, greaterThan(generation));
  });

  test('the tombstone expires with the grace: a resume after it finds '
      'nobody, as before', () async {
    final host = await start(
      linkResumeGrace: const Duration(milliseconds: 1500),
    );
    final (dialer, store, net, logs) = await client(host);
    final link = await dialer.dial(
      (await CompanionPairing.load(store))!,
      resumeOffered: () => true,
    );
    addTearDown(() => link.close());

    await overflowWhileAway(net);
    // Past the server's grace: the generation is closed for good.
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    net.up = true;
    await until(
      () => serverLogs.contains('lan hello for an unknown rendezvous'),
    );
    expect(serverLogs, isNot(contains(contains('refused a link.resume'))));
    expect(link.isClosed, isFalse);
  });

  test('a client that never resumes is untouched by the tombstone: its '
      'next dial is served on the next generation', () async {
    final host = await start();
    final (dialer, store, net, _) = await client(host);
    final link = await dialer.dial(
      (await CompanionPairing.load(store))!,
      resumeOffered: () => false,
    );

    await overflowWhileAway(net);
    // Without a resume the client's link ends at the drop.
    await link.done.timeout(const Duration(seconds: 5));

    net.up = true;
    final again = await dialer.dial((await CompanionPairing.load(store))!);
    addTearDown(() => again.close());
    expect(await echo(again, [4, 5]), [4, 5]);
    expect(serverLogs, isNot(contains(contains('refused a link.resume'))));
  });
}

class ClientNet {
  bool up = true;
  RemoteTransport? live;
}
