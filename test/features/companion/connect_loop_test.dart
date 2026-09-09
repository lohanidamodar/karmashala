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

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala/src/features/remote/application/remote_host_service.dart';
import 'package:karmashala_remote/client.dart'
    as stored;
import 'package:karmashala_remote/client.dart';
import 'package:karmashala/src/features/remote/data/paired_device_dao.dart';
import 'package:karmashala_remote/pairing.dart' hide PairingException;
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:flutter_test/flutter_test.dart';

import '../remote/fake_bindings.dart';
import '../remote/transport_harness.dart';

/// A keystore as slow as a real one on a bad day, so a test can stand inside
/// the window the gateway used to lose deaths in instead of racing it.
class SlowStore implements stored.CompanionStore {
  SlowStore(this.disk);

  final Map<String, String> disk;

  /// Held open, every write waits here. The two keystore calls the connect
  /// loop makes around the answer to its dial — the generation counter from
  /// inside `connect()`, and the host's greeting written down straight after
  /// `connected` — are the windows in which a link can be torn down with
  /// nothing yet in existence for its death to land on, so a test needs to be
  /// able to stand in them.
  ///
  /// Held rather than *widened*: a `writeCost` of 400 real milliseconds made
  /// the window long enough to race a kill into on an idle machine and short
  /// enough to miss on a loaded one, which is a reading of the machine rather
  /// than of the loop.
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

  /// The bounds below are hang-guards, not the measurement — same reasoning as
  /// [awaitLink]. Neither test asks how fast the phone says hello or how fast
  /// the desktop answers a request, so a handshake bounded at 150ms and a
  /// request at 500ms were two extra ways to fail that protected nothing.
  ///
  /// Measured on this file before they were raised: the 150ms handshake bound
  /// expires **twice per run with no load at all** (`the socket came back but
  /// the host did not: TimeoutException after 0:00:00.150000`), and a request
  /// that is answered is answered in 23–30ms — so the 500ms one had headroom
  /// only until the machine was busy. A bound that expires on an idle machine
  /// is not a bound, it is the reading; two seconds is what the siblings use
  /// for machinery, and 90 seconds is a pairing that has not hung.
  RemoteCompanionGateway makeGateway({
    LanPathScout? scout,
    Duration pairingTimeout = const Duration(seconds: 90),
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
      requestTimeout: const Duration(seconds: 2),
      helloTimeout: const Duration(seconds: 2),
      reconnectBackoff: fastBackoff(),
    );
    gateways.add(gateway);
    return gateway;
  }

  /// How long a wait for a link state may take before it is a hang.
  ///
  /// Deliberately close to these tests' own three-minute budget rather than
  /// the twenty seconds two of the waits below used to allow. Neither test
  /// measures how FAST the phone reconnects — they measure that it reconnects
  /// at all, with a client behind the link — so a deadline tighter than the
  /// test's own was an extra way to fail that protected nothing, and under
  /// `--concurrency=4` it fired: `TimeoutException after 0:00:20`.
  Future<void> awaitLink(
    RemoteCompanionGateway gateway,
    CompanionLinkState wanted, {
    Duration timeout = const Duration(seconds: 150),
  }) => gateway.linkStates
      .firstWhere((state) => state == wanted)
      .timeout(timeout);

  /// Polls until [check] holds, so a test can wait on a fact rather than on a
  /// stream that seeds its current value and would answer instantly.
  /// Same reasoning as [awaitLink]: a wait for a fact is machinery, not the
  /// measurement, so its deadline sits near the test's own budget.
  Future<void> until(
    bool Function() check, {
    Duration timeout = const Duration(seconds: 60),
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

    var arming = false;
    var killed = false;
    // Completes when the desktop is really gone, not merely on its way out:
    // the restart below must not overwrite `service` from under the stop that
    // is still running.
    final killDone = Completer<void>();
    // Every state the phone published, in order. The re-dial below is asserted
    // against this rather than against a clock.
    final seen = <CompanionLinkState>[];
    int cameUp() => seen.where((s) => s == CompanionLinkState.connected).length;
    final watch = gateway.linkStates.listen((state) {
      seen.add(state);
      if (state != CompanionLinkState.connected || !arming || killed) return;
      killed = true;
      // The window opens here and is HELD open. The loop has said `connected`
      // and its next awaited work is writing the host's greeting down; with
      // every write blocked it cannot get past that to the completer a death
      // would land on, however long the kill below takes.
      store.gate = Completer<void>();
      // Inside the window: the desktop goes away and the socket bounces, so
      // the phone's re-proof finds nobody and declares the link dead — with
      // nothing yet in existence for that death to land on.
      unawaited(() async {
        await service?.stop();
        service = null;
        await phoneTransports.last.abort();
        killDone.complete();
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

    // Three facts, each awaited: the phone got there, the desktop is down,
    // and the loop is standing in the window rather than past it. The last is
    // what a `writeCost` window could never assert — it hoped.
    await until(() => killed, reason: 'the phone reaches connected again');
    await killDone.future;
    await until(
      () => store.gated > 0,
      reason: 'the loop is inside the write the death has to land under',
    );

    // How many times the link had come up when the death was handed over.
    final cameUpAtDeath = cameUp();
    store.gate!.complete();
    store.gate = null;
    await until(
      () => gateway.link != CompanionLinkState.connected,
      reason: 'the phone acts on the death it was handed mid-dial',
    );

    // The desktop comes back. Nobody touches the phone: it must re-dial on
    // its own, exactly as it does after any other outage.
    await startService(localRelayUrl: Uri.parse('ws://127.0.0.1:2'));
    await awaitLink(gateway, CompanionLinkState.connected);
    // The second coming-up, counted — not `awaitLink` alone, which seeds the
    // state the phone is already in and would be answered by the link that
    // died. Whether the loop re-dialled or the transport healed itself is the
    // transport's business; that the phone got back up after a death nothing
    // was waiting for is this test's.
    expect(
      cameUp(),
      greaterThan(cameUpAtDeath),
      reason: 'the link came up again; it did not park on a death it lost',
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
    await awaitLink(gateway, CompanionLinkState.connected);
    expect(
      (await gateway.listSessions()).single.id,
      's1',
      reason: 'a link that says connected must have a client behind it',
    );
  });
}
