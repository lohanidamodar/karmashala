/// "It says connecting to desktop again, sometimes host unreachable — the
/// connection keeps dropping."
///
/// The bug behind that report: a socket at a rendezvous is not a link. The
/// relay accepts one whether or not the host is at the other end, and holds a
/// lonely socket for two minutes before hanging up with `kCloseNoPeer`. The
/// gateway used to read "transport reconnected" as "host is back", so it
/// claimed **connected** to a rendezvous nobody was at — every request then
/// failed or timed out, which declared the link dead, which re-dialled, which
/// reconnected the socket, which claimed connected again. Forever.
///
/// These tests drive the real gateway against a real in-process relay whose
/// lone timeout is milliseconds instead of minutes, so the whole loop runs in
/// a few seconds.
library;

import 'package:karmashala_store/database.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala/src/features/companion/client/secure_companion_store.dart';
import 'package:karmashala/src/features/remote/application/remote_host_service.dart';
import 'package:karmashala/src/features/remote/data/paired_device_dao.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:flutter_test/flutter_test.dart';

import '../remote/fake_bindings.dart';
import '../remote/transport_harness.dart';

void main() {
  late AppDatabase db;
  late PairedDeviceDao dao;
  late FakeRemoteBindings fake;
  late RelayServer relay;
  late Uri relayUri;
  RemoteHostService? service;
  late Map<String, String> phoneDisk;
  late SecureCompanionStore store;
  final gateways = <RemoteCompanionGateway>[];

  final hostId = DeviceId.parse('11111111222222223333333344444444');

  setUp(() async {
    db = AppDatabase.memory();
    dao = PairedDeviceDao(db);
    fake = FakeRemoteBindings()..addSession('s1');
    // The relay's own policy, compressed: a rendezvous holding one lonely
    // socket is disposed with kCloseNoPeer. Two minutes in production, five
    // seconds here — still comfortably longer than this suite's hello
    // timeout, so the phone's own handshake is what decides the link's fate,
    // exactly as it does on a real relay.
    relay = await RelayServer.bind(
      address: '127.0.0.1',
      port: 0,
      options: const RelayOptions(loneTimeout: Duration(seconds: 5)),
    );
    relayUri = Uri.parse('http://127.0.0.1:${relay.port}');
    phoneDisk = {
      RemoteCompanionGateway.kPairingRelayStoreKey: relayUri.toString(),
    };
    store = SecureCompanionStore.withBackend(
      read: (key) async => phoneDisk[key],
      write: (key, value) async => phoneDisk[key] = value,
      delete: (key) async => phoneDisk.remove(key),
    );
  });

  tearDown(() async {
    for (final gateway in gateways.reversed.toList()) {
      await gateway.close();
    }
    gateways.clear();
    await service?.stop();
    service = null;
    await relay.close();
    db.close();
  });

  Future<RemoteHostService> startService() async {
    final started = service = RemoteHostService(
      devices: dao,
      hostId: hostId,
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
    await started.start();
    return started;
  }

  RemoteCompanionGateway makeGateway() {
    final gateway = RemoteCompanionGateway(
      store: store,
      deviceModel: 'Test phone',
      relayFactory: (relay, rendezvous) => RelayTransport(
        endpoint: RelayTransport.endpointFor(relay, rendezvous),
        backoff: fastBackoff(),
        heartbeat: const Duration(milliseconds: 500),
      )..start(),
      requestTimeout: const Duration(milliseconds: 700),
      helloTimeout: const Duration(milliseconds: 500),
      reconnectBackoff: fastBackoff(),
    );
    gateways.add(gateway);
    return gateway;
  }

  Future<void> awaitLink(
    RemoteCompanionGateway gateway,
    CompanionLinkState wanted,
  ) => gateway.linkStates
      .firstWhere((state) => state == wanted)
      .timeout(const Duration(seconds: 60));

  Future<RemoteCompanionGateway> pairedPhone() async {
    final gateway = makeGateway();
    final session = await service!.beginPairing(capabilities: CapabilitySet.all);
    await gateway.pairWithQr(session.payload.encode());
    await session.done;
    await awaitLink(gateway, CompanionLinkState.connected);
    return gateway;
  }

  Future<void> settle(Duration duration) => Future<void>.delayed(duration);

  Future<void> eventually(
    Future<bool> Function() check, {
    Duration timeout = const Duration(seconds: 20),
    String reason = 'condition',
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (await check()) return;
      if (DateTime.now().isAfter(deadline)) fail('never happened: $reason');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('a desktop that went away is never reported as connected, however '
      'healthy the socket looks', timeout: const Timeout(Duration(minutes: 2)),
      () async {
    await startService();
    final gateway = await pairedPhone();

    // Everything from here is what the phone claims AFTER the desktop is gone.
    final claimed = <CompanionLinkState>[];
    final stamps = <DateTime?>[];
    final watching = gateway.linkStates.listen(claimed.add);
    final stamping = gateway.linkSinceStates.listen(stamps.add);
    addTearDown(watching.cancel);
    addTearDown(stamping.cancel);
    await service!.stop();
    service = null;

    // The relay kicks the lonely socket, the transport redials it, and the
    // relay takes it again — the exact moment the old code said "connected".
    await settle(const Duration(seconds: 4));
    // Both at once: an await between them would let one more report land on
    // the survivor and make the counts below disagree for nothing.
    await Future.wait([watching.cancel(), stamping.cancel()]);

    // The first entry is the connected state it was in when we subscribed.
    expect(claimed.first, CompanionLinkState.connected);
    expect(
      claimed.skip(1),
      isNot(contains(CompanionLinkState.connected)),
      reason: 'a rendezvous with nobody at it is not a connection',
    );
    expect(gateway.link, isNot(CompanionLinkState.connected));
    // And it says something true about why, rather than blaming the network.
    expect(gateway.linkTrouble, contains('relay'));

    // The link's age is stamped per CHANGE, not per report: the redial above
    // reports a state the phone is already in, and a stamp that followed every
    // report would read "just now" for an outage of any age (CLAUDE.md §19).
    // The first frame is the stamp already held when we subscribed.
    var changes = 0;
    for (var i = 1; i < claimed.length; i++) {
      if (claimed[i] != claimed[i - 1]) changes++;
    }
    expect(
      stamps.length - 1,
      changes,
      reason: '${claimed.length} reports carried $changes changes',
    );
    expect(gateway.linkSince, isNotNull);
  });

  test('when the desktop comes back the phone reconnects on its own, and the '
      'link works', timeout: const Timeout(Duration(minutes: 2)), () async {
    await startService();
    final gateway = await pairedPhone();
    await service!.stop();
    service = null;
    await awaitLink(gateway, CompanionLinkState.disconnected);

    // Nobody touches the phone: the desktop simply comes back.
    await startService();

    await awaitLink(gateway, CompanionLinkState.connected);
    expect((await gateway.listSessions()).single.id, 's1');
    expect(gateway.linkTrouble, isNull, reason: 'the trouble is over');
  });

  test('an IDLE phone notices the desktop is gone — nobody has to tap '
      'anything to find out', timeout: const Timeout(Duration(minutes: 2)),
      () async {
    await startService();
    final gateway = await pairedPhone();
    // Not a single request from here on: the only thing that can discover the
    // desktop's absence is the link proving itself.
    await service!.stop();
    service = null;

    await awaitLink(gateway, CompanionLinkState.disconnected);
    await eventually(
      () async => gateway.linkTrouble != null,
      reason: 'the phone says why, once it has actually tried',
    );

    expect(
      gateway.linkTrouble,
      allOf(contains('not answering'), contains('relay')),
      reason: 'the phone knows the desktop is absent, not that wifi broke',
    );
    expect(gateway.link, isNot(CompanionLinkState.connected));
  });
}
