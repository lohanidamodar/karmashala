/// The connect loop's two ways out, and what happens when one is lost.
///
/// Owner: "mobile pairs but unable to connect, just connecting to your
/// desktop and nothing to show yet" — and, separately, "mobile connection is
/// not stable, keeps dropping even though desktop is working and live".
///
/// The loop leaves `connecting` only when a dial returns, and leaves a live
/// link only when its death completer fires. Both could go missing: a death
/// declared while the link was still being brought up had no completer to
/// land on and was thrown away, and a beacon from a desktop the phone cannot
/// dial directly killed a working relay link on a two-minute schedule.
library;

import 'dart:async';

import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/companion/client/companion_gateway.dart';
import 'package:chitragupta/src/features/companion/client/remote_companion_gateway.dart';
import 'package:chitragupta/src/features/remote/application/remote_host_service.dart';
import 'package:chitragupta/src/features/remote/client/companion_store.dart'
    as stored;
import 'package:chitragupta/src/features/remote/client/lan_path.dart';
import 'package:chitragupta/src/features/remote/data/paired_device_dao.dart';
import 'package:chitragupta/src/features/remote/pairing/pairing_code.dart';
import 'package:chitragupta/src/features/remote/protocol.dart';
import 'package:chitragupta/src/features/remote/transport/relay_transport.dart';
import 'package:chitragupta_relay/chitragupta_relay.dart';
import 'package:flutter_test/flutter_test.dart';

import '../remote/fake_bindings.dart';
import '../remote/transport_harness.dart';

/// A keystore as slow as a real one on a bad day, so a test can stand inside
/// the window the gateway used to lose deaths in instead of racing it.
class SlowStore implements stored.CompanionStore {
  SlowStore(this.disk);

  final Map<String, String> disk;
  Duration writeCost = Duration.zero;

  /// Held open, every write waits here. The keystore call the connect loop
  /// makes from INSIDE its dial — persisting the generation counter — is the
  /// one window in which a link can be torn down under a `connect()` that has
  /// already been answered, so a test needs to be able to stand in it.
  Completer<void>? gate;

  /// How many writes the gate has held.
  int gated = 0;

  @override
  Future<String?> read(String key) async => disk[key];

  @override
  Future<void> write(String key, String value) async {
    final waiting = gate;
    if (waiting != null) {
      gated++;
      await waiting.future;
    }
    if (writeCost > Duration.zero) await Future<void>.delayed(writeCost);
    disk[key] = value;
  }

  @override
  Future<void> delete(String key) async => disk.remove(key);
}

void main() {
  late AppDatabase db;
  late PairedDeviceDao dao;
  late FakeRemoteBindings fake;
  late RelayServer relay;
  late Uri relayUri;
  RemoteHostService? service;
  late Map<String, String> phoneDisk;
  late SlowStore store;
  final gateways = <RemoteCompanionGateway>[];
  final phoneTransports = <RelayTransport>[];

  final hostId = DeviceId.parse('11111111222222223333333344444444');

  setUp(() async {
    db = AppDatabase.memory();
    dao = PairedDeviceDao(db);
    fake = FakeRemoteBindings()..addSession('s1');
    relay = await RelayServer.bind(
      address: '127.0.0.1',
      port: 0,
      options: const RelayOptions(loneTimeout: Duration(seconds: 30)),
    );
    relayUri = Uri.parse('http://127.0.0.1:${relay.port}');
    phoneDisk = {
      RemoteCompanionGateway.kPairingRelayStoreKey: relayUri.toString(),
    };
    store = SlowStore(phoneDisk);
    phoneTransports.clear();
  });

  tearDown(() async {
    store.writeCost = Duration.zero;
    // A held gate would deadlock the shutdown as surely as it holds the dial.
    if (store.gate?.isCompleted == false) store.gate!.complete();
    store.gate = null;
    for (final gateway in gateways.reversed.toList()) {
      await gateway.close();
    }
    gateways.clear();
    await service?.stop();
    service = null;
    await relay.close();
    db.close();
  });

  Future<RemoteHostService> startService({Uri? localRelayUrl}) async {
    final started = service = RemoteHostService(
      devices: dao,
      hostId: hostId,
      bindings: fake.bindings,
      relay: relayUri,
      localRelayUrl: localRelayUrl,
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

  RemoteCompanionGateway makeGateway({
    LanPathScout? scout,
    Duration pairingTimeout = const Duration(seconds: 20),
  }) {
    final gateway = RemoteCompanionGateway(
      store: store,
      deviceName: 'Test phone',
      lan: scout,
      pairingTimeout: pairingTimeout,
      relayFactory: (relay, rendezvous) {
        final transport = RelayTransport(
          endpoint: RelayTransport.endpointFor(relay, rendezvous),
          backoff: fastBackoff(),
          heartbeat: const Duration(milliseconds: 500),
        )..start();
        phoneTransports.add(transport);
        return transport;
      },
      requestTimeout: const Duration(milliseconds: 500),
      helloTimeout: const Duration(milliseconds: 150),
      reconnectBackoff: fastBackoff(),
    );
    gateways.add(gateway);
    return gateway;
  }

  Future<void> awaitLink(
    RemoteCompanionGateway gateway,
    CompanionLinkState wanted, {
    Duration timeout = const Duration(seconds: 30),
  }) => gateway.linkStates
      .firstWhere((state) => state == wanted)
      .timeout(timeout);

  /// Polls until [check] holds, so a test can wait on a fact rather than on a
  /// stream that seeds its current value and would answer instantly.
  Future<void> until(
    bool Function() check, {
    Duration timeout = const Duration(seconds: 20),
    required String reason,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!check()) {
      if (DateTime.now().isAfter(deadline)) fail('never happened: $reason');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<RemoteCompanionGateway> pairedPhone({LanPathScout? scout}) async {
    final gateway = makeGateway(scout: scout);
    final session = await service!.beginPairing(capabilities: CapabilitySet.all);
    await gateway.pairWithQr(session.payload.encode());
    await session.done;
    await awaitLink(gateway, CompanionLinkState.connected);
    return gateway;
  }

  test('a link that dies while it is still coming up is re-dialled, not '
      'parked on for ever', timeout: const Timeout(Duration(minutes: 3)),
      () async {
    await startService();
    final gateway = await pairedPhone();

    // From here every keystore write is slow, which is what widens the window
    // between "the dial came back" and "the loop is watching for a death"
    // from microseconds to something a test can stand inside. On a phone that
    // window is the platform channel's own latency.
    store.writeCost = const Duration(milliseconds: 400);

    var arming = false;
    var killed = false;
    final watch = gateway.linkStates.listen((state) {
      if (state != CompanionLinkState.connected || !arming || killed) return;
      killed = true;
      // Inside the window: the desktop goes away and the socket bounces, so
      // the phone's re-proof finds nobody and declares the link dead — with
      // nothing yet in existence for that death to land on.
      unawaited(() async {
        await service?.stop();
        service = null;
        await phoneTransports.last.abort();
      }());
    });
    addTearDown(watch.cancel);

    // Force a fresh pass through that window.
    await service!.stop();
    service = null;
    await awaitLink(gateway, CompanionLinkState.disconnected);
    // A relay set the phone has not seen before, so the host's greeting
    // really does have to be written down — which is the awaited keystore
    // work the loop used to lose deaths behind.
    arming = true;
    await startService(localRelayUrl: Uri.parse('ws://127.0.0.1:1'));
    while (!killed) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(seconds: 3));
    store.writeCost = Duration.zero;

    // The desktop comes back. Nobody touches the phone: it must re-dial on
    // its own, exactly as it does after any other outage.
    await startService(localRelayUrl: Uri.parse('ws://127.0.0.1:2'));
    await awaitLink(
      gateway,
      CompanionLinkState.connected,
      timeout: const Duration(seconds: 20),
    );
    expect((await gateway.listSessions()).single.id, 's1');
  });

  test('a dial answered after its link was torn down is dropped, not adopted',
      timeout: const Timeout(Duration(minutes: 3)), () async {
    await startService();
    // Pair, then let that gateway go: the record it leaves on the phone's
    // disk is what the next one wakes up dialling, which is where the window
    // this test stands in opens.
    final first = await pairedPhone();
    await first.close();

    // Every keystore write now blocks. The first one a fresh gateway makes is
    // the generation counter its dial persists AFTER the host has answered
    // the hello — the one stretch of a dial that cannot be cancelled.
    store.gate = Completer<void>();
    final gateway = makeGateway(pairingTimeout: const Duration(seconds: 2));
    await until(
      () => store.gated > 0,
      reason: 'the dial reaches the keystore write inside connect()',
    );

    // A typed code nobody is serving. It decodes, so the gateway drops the
    // link it is holding before it goes looking — and that teardown lands
    // under the dial that is still in flight.
    final pairing = expectLater(
      gateway.pairWithCode(PairingCode.encode(List<int>.generate(20, (i) => i))),
      throwsA(isA<PairingException>()),
    );
    await until(
      () => gateway.link == CompanionLinkState.disconnected,
      reason: 'the pairing attempt tears the old link down first',
    );

    // Now let the dial finish. Nothing owns the client it answers with.
    store.gate!.complete();
    store.gate = null;
    await pairing;

    // Whatever the loop does next, "connected" has to mean a desktop this
    // phone can actually ask for something. Adopting the orphaned client
    // parks the loop on a completer nothing can fire, with `connected` on
    // screen and no client behind it.
    await awaitLink(
      gateway,
      CompanionLinkState.connected,
      timeout: const Duration(seconds: 20),
    );
    expect(
      (await gateway.listSessions()).single.id,
      's1',
      reason: 'a link that says connected must have a client behind it',
    );
  });
}
