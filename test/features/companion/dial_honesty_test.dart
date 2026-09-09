/// What one dial is allowed to cost, and what it is allowed to claim.
///
/// Owner: "mobile pairs but unable to connect, just connecting to your
/// desktop and nothing to show."
///
/// Two separate facts hide behind that one screen. A relay that will not take
/// the socket says nothing at all about the desktop — and, before this, cost
/// the phone the FULL hello window three times over, once per generation it
/// probed forward, for an address that was never going to answer. With a set
/// of saved relays (Loop 83) that is minutes of "Connecting…" per pass, which
/// to the person holding the phone is indistinguishable from stuck.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala/src/features/companion/client/secure_companion_store.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:flutter_test/flutter_test.dart';

import '../remote/transport_harness.dart';

/// A relay address nothing is listening on, so every dial is refused at once.
final Uri _deadRelay = Uri.parse('ws://127.0.0.1:1');

CompanionPairing _pairing(Uri relay) => CompanionPairing(
  hostId: DeviceId.parse('11111111222222223333333344444444'),
  deviceId: DeviceId.parse('aaaaaaaabbbbbbbbccccccccdddddddd'),
  deviceKey: Uint8List.fromList(List<int>.filled(32, 7)),
  capabilities: CapabilitySet.all,
  relay: relay,
  generation: 1,
  hostName: 'Desktop',
);

void main() {
  test('a relay that never takes the socket is dialled ONCE, and says so '
      'about the relay rather than about the desktop', () async {
    var dials = 0;
    final client = CompanionClient(
      pairing: _pairing(_deadRelay),
      store: InMemoryCompanionStore(),
      relayFactory: (relay, rendezvous) {
        dials++;
        return RelayTransport(
          endpoint: RelayTransport.endpointFor(relay, rendezvous),
          backoff: fastBackoff(),
          connectTimeout: const Duration(milliseconds: 100),
        )..start();
      },
    );
    addTearDown(client.close);

    await expectLater(
      client.connect(helloTimeout: const Duration(milliseconds: 400)),
      throwsA(
        isA<RemoteApiException>()
            .having((e) => e.relayUnreachable, 'relayUnreachable', isTrue)
            .having((e) => e.hostAbsent, 'hostAbsent', isFalse),
      ),
    );
    expect(
      dials,
      1,
      reason: 'probing a generation forward is pointless at a relay that is '
          'silent at every generation',
    );
  });

  test('a relay that DOES take the socket, with no host behind it, is still '
      'probed forward and reported as an absent host', () async {
    final relay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    addTearDown(relay.close);
    var dials = 0;
    final client = CompanionClient(
      pairing: _pairing(Uri.parse('http://127.0.0.1:${relay.port}')),
      store: InMemoryCompanionStore(),
      relayFactory: (url, rendezvous) {
        dials++;
        return RelayTransport(
          endpoint: RelayTransport.endpointFor(url, rendezvous),
          backoff: fastBackoff(),
        )..start();
      },
    );
    addTearDown(client.close);

    await expectLater(
      // **Long enough that it cannot be mistaken for connect latency.** The
      // verdict this test asserts turns on `socketOpened`: when the hello
      // times out, `connect` says *relay unreachable* if the socket never
      // opened and probes forward if it did. At 300 ms that timeout fired
      // before a loopback connect finished under gate load — four
      // `flutter_tester` processes and a machine doing other work — so a relay
      // that had taken the socket was reported as one that could not be
      // reached, which is the opposite of what this case is named for.
      //
      // The failure modes are asymmetric, which is why this errs long: too
      // short is a false failure, too long is only a slower test. Nothing here
      // waits *for* the timeout to prove anything — the hello never arrives —
      // so the bound is an upper limit on something that will not happen, and
      // making it generous weakens no assertion.
      client.connect(helloTimeout: const Duration(seconds: 2)),
      throwsA(
        isA<RemoteApiException>()
            .having((e) => e.hostAbsent, 'hostAbsent', isTrue)
            .having((e) => e.relayUnreachable, 'relayUnreachable', isFalse),
      ),
    );
    expect(dials, kCompanionProbeWindow);
  });

  test('a keystore that never answers is a keystore that failed — the call '
      'comes back, so the connect loop behind it can go on', () async {
    final store = SecureCompanionStore.withBackend(
      read: (_) => Completer<String?>().future,
      write: (_, _) => Completer<void>().future,
      delete: (_) => Completer<void>().future,
      timeout: const Duration(milliseconds: 100),
    );

    // A read that never answers is a read that failed: unpaired, not hung.
    expect(await store.read('k'), isNull);
    // A write that never answers fails out loud, so the caller can decide.
    await expectLater(store.write('k', 'v'), throwsA(isA<TimeoutException>()));
    await expectLater(store.delete('k'), throwsA(isA<TimeoutException>()));
  });

  test('a stalled write cannot wedge the connection-set chain for good',
      () async {
    // `CompanionConnections.mutate` serialises every read-modify-write on one
    // static chain. Before the store had a deadline, ONE keystore call that
    // never came back stopped every later one for the life of the process —
    // and the connect loop persists its counter inside the dial.
    final stalled = SecureCompanionStore.withBackend(
      read: (_) => Completer<String?>().future,
      write: (_, _) => Completer<void>().future,
      delete: (_) => Completer<void>().future,
      timeout: const Duration(milliseconds: 100),
    );
    await expectLater(
      CompanionConnections.mutate(stalled, (all) => all),
      throwsA(isA<TimeoutException>()),
    );

    // The next mutation, on a store that works, still runs.
    final healthy = InMemoryCompanionStore();
    final after = await CompanionConnections.mutate(
      healthy,
      (all) => all..upsert(_pairing(_deadRelay)),
    ).timeout(const Duration(seconds: 5));
    expect(after.records, hasLength(1));
  });
}
