/// The owner's report: "paired, projects and sessions show, but opening a
/// session fails". The phone logged, once every fifteen seconds, for ever:
///
/// ```
/// subscribe <id> failed: RemoteApiException(null: the host did not answer)
/// a request went unanswered; the link itself still holds
/// ```
///
/// while the desktop's own log said nothing at all about it.
///
/// The cause is in this file's subject. A phone that comes back on a
/// generation it has already used builds a **fresh** [SealedChannel], whose
/// send sequence restarts at zero. The host still held the OLD channel for
/// that generation, whose replay window has already seen those sequences — so
/// every request the phone sends is refused as a replay and dropped in
/// silence. The plaintext `LinkHello` is answered regardless (it never goes
/// through the channel), so the phone is told `host.status`, calls itself
/// connected, and then waits for answers that can never arrive.
///
/// The escape has to be the generation, not the replay window: resetting the
/// window would be the one thing standing between a captured frame and being
/// played back into this generation. So the host retires the generation, whose
/// successor is keyed differently, and the phone's probe-forward window walks
/// onto it by itself.
library;

import 'dart:typed_data';

import 'package:karmashala_store/database.dart';
import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_store/devices.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bindings.dart';
import 'transport_harness.dart';

final _hostId = DeviceId.parse('11111111222222223333333344444444');
final _phone = DeviceId.parse('aaaaaaaabbbbbbbbccccccccdddddddd');
final _secret = Uint8List.fromList(List<int>.generate(32, (i) => 0x51 + i));

void main() {
  late AppDatabase db;
  late PairedDeviceDao dao;
  late FakeRemoteBindings fake;
  late RelayServer relay;
  late Uri relayUri;
  RemoteHostService? service;
  final cleanups = <Future<void> Function()>[];
  final hostLog = <String>[];

  setUp(() async {
    db = AppDatabase.memory();
    dao = PairedDeviceDao(db);
    fake = FakeRemoteBindings()..addSession('s1');
    hostLog.clear();
    // Its own ephemeral port, never 8787: a test that leaks a listener onto
    // the machine's real relay port poisons every run after it.
    relay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    relayUri = Uri.parse('http://127.0.0.1:${relay.port}');
  });

  tearDown(() async {
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

  RemoteTransport dial(Uri url, RendezvousId rendezvous) => RelayTransport(
    endpoint: RelayTransport.endpointFor(url, rendezvous),
    backoff: fastBackoff(),
    heartbeat: const Duration(milliseconds: 500),
  )..start();

  Future<void> startService() async {
    dao.insert(
      PairedDevice(
        id: _phone.value,
        name: 'phone',
        deviceKey: await keyFor(_phone),
        capabilities: CapabilitySet.all,
        generation: kFirstSessionGeneration,
        createdAt: DateTime.utc(2026, 9),
        relayUrl: kLocalRelayMarker,
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
      transcriptPollInterval: Duration.zero,
      onLog: hostLog.add,
      relayFactory: dial,
    );
    await started.start();
  }

  /// A phone whose stored counter says [generation] — which is what a phone
  /// whose keystore write never landed comes back holding.
  Future<CompanionClient> phoneAt(int generation) async {
    final client = CompanionClient(
      pairing: CompanionPairing(
        hostId: _hostId,
        deviceId: _phone,
        deviceKey: await keyFor(_phone),
        capabilities: CapabilitySet.all,
        relay: relayUri,
        generation: generation,
        hostName: 'TestHost',
      ),
      store: InMemoryCompanionStore(),
      requestTimeout: const Duration(seconds: 3),
      relayFactory: dial,
    );
    cleanups.add(client.close);
    return client;
  }

  int hostGeneration() => dao.getById(_phone.value)!.generation;

  test('both ends of one pairing meet at the same rendezvous', () async {
    // The host listens at its stored counter and the next few; the phone dials
    // its own and probes forward. The two windows have to overlap, and the two
    // ends have to derive byte-identical ids from the same device key — this
    // is the contract every other test in this file rests on.
    final key = SecretKeyData(await keyFor(_phone));
    final hostWindow = [
      for (
        var g = kFirstSessionGeneration;
        g < kFirstSessionGeneration + kHostRelayListenWindow;
        g++
      )
        (await rendezvousFor(key, g)).value,
    ];
    final phoneWindow = [
      for (var probe = 0; probe < kCompanionProbeWindow; probe++)
        (await rendezvousFor(key, kFirstSessionGeneration + probe)).value,
    ];
    expect(
      hostWindow.toSet().intersection(phoneWindow.toSet()),
      isNotEmpty,
      reason: 'a phone that dials its own counter must find the host there',
    );
    expect(phoneWindow.first, hostWindow.first);
    // And a rendezvous is a path, never an identity: the same id on the same
    // relay is the same URL on both sides, byte for byte.
    final id = RendezvousId.parse(hostWindow.first);
    expect(
      RelayTransport.endpointFor(relayUri, id).toString(),
      endsWith('/v1/${id.value}'),
    );
  });

  test(
    'a phone that comes back on a generation it already used gets a link '
    'that works, not one that answers nothing for ever',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      await startService();

      // One ordinary session: the phone connects and its requests are answered,
      // which is what fills the host channel's replay window.
      final first = await phoneAt(kFirstSessionGeneration);
      await first.connect(helloTimeout: const Duration(seconds: 5));
      expect(await first.listSessions(), hasLength(1));
      await first.close();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // The counter bump never reached the phone's keystore — a write that timed
      // out, or the app killed before it landed — so the phone comes back on the
      // generation it has already used, with a brand new channel. The host
      // greets it (the hello never goes through the channel) and then cannot
      // admit a thing it sends.
      final second = await phoneAt(kFirstSessionGeneration);
      expect(
        (await second.connect(
          helloTimeout: const Duration(seconds: 5),
        )).hostName,
        'TestHost',
      );
      await expectLater(
        second.listSessions(),
        throwsA(isA<RemoteApiException>()),
      );

      // That is where the owner's phone stayed, for ever. What has to be true
      // now is that the desktop noticed, said so, and left the poisoned
      // generation behind — because the next dial is the one that has to work.
      expect(
        hostLog.where((line) => line.startsWith('retiring generation')),
        isNotEmpty,
        reason:
            'a desktop that refuses every frame has to say why: this cost a '
            'forensic dig through a log that recorded nothing at all',
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // The phone dials its own bumped counter, which is exactly where the host
      // now is. Nobody re-paired, nobody touched a setting.
      final third = await phoneAt(second.pairing.generation);
      await third.connect(helloTimeout: const Duration(seconds: 5));
      expect(await third.listSessions(), hasLength(1));
      await third.subscribeSession('s1');
    },
  );

  test(
    'the poisoned generation is left behind, not reset — nothing sent in '
    'it can be replayed into the one that replaces it',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      await startService();
      final first = await phoneAt(kFirstSessionGeneration);
      await first.connect(helloTimeout: const Duration(seconds: 5));
      await first.listSessions();
      await first.close();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final second = await phoneAt(kFirstSessionGeneration);
      await second.connect(helloTimeout: const Duration(seconds: 5));
      await second.listSessions().catchError(
        (Object _) => <RemoteSessionSnapshot>[],
      );

      expect(
        hostGeneration(),
        greaterThan(kFirstSessionGeneration),
        reason:
            'the replay window is the only thing stopping a captured frame '
            'being played back into a generation, so the way out is a new '
            'generation — never a reset window',
      );
    },
  );

  test(
    'a frame whose seal does not verify never costs the link',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      await startService();
      final phone = await phoneAt(kFirstSessionGeneration);
      await phone.connect(helloTimeout: const Duration(seconds: 5));
      await phone.listSessions();
      final generation = phone.generation;
      await phone.close();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // A stranger at the rendezvous — or a relay playing games — can put bytes
      // on the wire, and proves nothing by doing it. Letting that retire a
      // generation would hand anyone who can reach the meeting place a way to
      // rotate the link at will.
      final key = SecretKeyData(await keyFor(_phone));
      final intruder = dial(relayUri, await rendezvousFor(key, generation));
      cleanups.add(intruder.close);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      intruder.send(Uint8List.fromList(List<int>.filled(96, 0x7f)));
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(
        hostGeneration(),
        generation,
        reason: 'junk that never opened says nothing about the paired phone',
      );
    },
  );
}
