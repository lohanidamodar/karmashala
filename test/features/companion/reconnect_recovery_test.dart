/// What the phone is entitled to see after a reconnect.
///
/// The axis that was never written down, and the reason it went unnoticed: a
/// transcript missing turns looks exactly like a session that has been quiet.
/// A reconnect used to answer it by re-reading the *tail*, which is right only
/// while the gap is smaller than one page. Past that the conversation was
/// silently replaced by its end, with a line about "earlier messages" standing
/// in for turns this phone had already been shown.
///
/// So a reconnect resumes from the cursor and pages forward until the host says
/// there is nothing newer. Real sockets, a real relay and the real host service
/// throughout — the claim is about two builds talking, not about a mock.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala/src/features/remote/application/remote_host_service.dart';
import 'package:karmashala_remote/client.dart'
    as stored;
import 'package:karmashala/src/features/remote/data/paired_device_dao.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_relay/karmashala_relay.dart';

import '../remote/fake_bindings.dart';
import '../remote/transport_harness.dart';

void main() {
  late AppDatabase db;
  late PairedDeviceDao dao;
  late FakeRemoteBindings fake;
  late RelayServer relay;
  late Uri relayUri;
  RemoteHostService? service;
  late stored.InMemoryCompanionStore store;
  final gateways = <RemoteCompanionGateway>[];

  final hostId = DeviceId.parse('11111111222222223333333344444444');
  const heartbeat = Duration(milliseconds: 300);

  setUp(() async {
    db = AppDatabase.memory();
    dao = PairedDeviceDao(db);
    fake = FakeRemoteBindings()..addSession('s1');
    relay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    relayUri = Uri.parse('ws://127.0.0.1:${relay.port}');
    store = stored.InMemoryCompanionStore();
    store.values[RemoteCompanionGateway.kPairingRelayStoreKey] =
        relayUri.toString();
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
      localRelayUrl: relayUri,
      hostedEnabled: false,
      lanPort: 0,
      advertise: false,
      // The sweep is what carries live growth; a zero interval leaves the
      // recovery walk as the only thing that can close a gap, which is the
      // claim being made.
      transcriptPollInterval: Duration.zero,
      relayFactory: (url, rendezvous) => RelayTransport(
        endpoint: RelayTransport.endpointFor(url, rendezvous),
        backoff: fastBackoff(),
        heartbeat: heartbeat,
      )..start(),
    );
    await started.start();
    return started;
  }

  Future<RemoteCompanionGateway> pairedPhone() async {
    final gateway = RemoteCompanionGateway(
      store: store,
      deviceModel: 'Test phone',
      relayFactory: (url, rendezvous) => RelayTransport(
        endpoint: RelayTransport.endpointFor(url, rendezvous),
        backoff: fastBackoff(),
        heartbeat: heartbeat,
      )..start(),
      requestTimeout: const Duration(seconds: 5),
      helloTimeout: const Duration(milliseconds: 800),
      linkHealGrace: const Duration(milliseconds: 800),
      reconnectBackoff: fastBackoff(),
    );
    gateways.add(gateway);
    final session = await service!.beginPairing(
      capabilities: CapabilitySet.all,
      relay: relayUri,
      relayIsLocal: true,
    );
    await gateway.pairWithQr(session.payload.encode());
    await session.done;
    await gateway.linkStates
        .firstWhere((s) => s == CompanionLinkState.connected)
        .timeout(const Duration(seconds: 30));
    return gateway;
  }

  Future<void> until(
    bool Function() check, {
    Duration timeout = const Duration(seconds: 30),
    required String reason,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!check()) {
      if (DateTime.now().isAfter(deadline)) fail('never happened: $reason');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  void say(int count, {required int from}) {
    fake.transcripts.putIfAbsent('s1', () => []).addAll([
      for (var i = from; i < from + count; i++)
        RemoteTranscriptMessage(role: i.isEven ? 'user' : 'agent', text: 'm$i'),
    ]);
  }

  test('a reconnect after N missed turns yields exactly N, in order, once',
      timeout: const Timeout(Duration(minutes: 3)), () async {
    // Deliberately more than one page, because one page is where the old
    // answer stopped being right.
    const missed = kRemoteTranscriptPageMax * 2 + 11;

    await startService();
    final gateway = await pairedPhone();

    say(4, from: 0);
    final seen = <List<CompanionChatMessage>>[];
    final watch = gateway.transcript('s1').listen(seen.add);
    addTearDown(watch.cancel);
    await until(
      () => seen.isNotEmpty && seen.last.length == 4,
      reason: 'the opening read arrives',
    );

    await service!.stop();
    service = null;
    await gateway.linkStates
        .firstWhere((s) => s != CompanionLinkState.connected)
        .timeout(const Duration(seconds: 30));

    // Everything the phone was away for.
    say(missed, from: 4);

    await startService();
    await gateway.linkStates
        .firstWhere((s) => s == CompanionLinkState.connected)
        .timeout(const Duration(seconds: 30));
    await until(
      () => seen.last.length >= 4 + missed,
      reason: 'the recovery walk finishes',
    );

    final held = seen.last;
    expect(held, hasLength(4 + missed), reason: 'exactly N, and once');
    expect(
      held.map((m) => m.text).toList(),
      [for (var i = 0; i < 4 + missed; i++) 'm$i'],
      reason: 'in order, with nothing dropped from the middle',
    );
    // The tail re-read is what put this on screen, and it was a notice about
    // turns the reader had already been shown.
    expect(
      held.where((m) => m.text.contains('are not loaded')),
      isEmpty,
      reason: 'nothing was omitted, so nothing may claim it was',
    );
  });

  test('a reconnect with nothing missed adds nothing and repeats nothing',
      timeout: const Timeout(Duration(minutes: 3)), () async {
    await startService();
    final gateway = await pairedPhone();

    say(6, from: 0);
    final seen = <List<CompanionChatMessage>>[];
    final watch = gateway.transcript('s1').listen(seen.add);
    addTearDown(watch.cancel);
    await until(
      () => seen.isNotEmpty && seen.last.length == 6,
      reason: 'the opening read arrives',
    );

    await service!.stop();
    service = null;
    await gateway.linkStates
        .firstWhere((s) => s != CompanionLinkState.connected)
        .timeout(const Duration(seconds: 30));
    await startService();
    await gateway.linkStates
        .firstWhere((s) => s == CompanionLinkState.connected)
        .timeout(const Duration(seconds: 30));

    // Long enough for a recovery that was going to say something to say it.
    await Future<void>.delayed(const Duration(seconds: 2));

    expect(seen.last.map((m) => m.text).toList(), [
      for (var i = 0; i < 6; i++) 'm$i',
    ]);
  });
}
