/// The integration seam, end to end and in process: the real
/// [RemoteCompanionGateway] over the real [CompanionClient], through an
/// in-process relay, into the real [RemoteHostService] and [HostSessionApi]
/// over faked desktop bindings. No fake is load-bearing anywhere between the
/// gateway surface and the desktop's provider seams.
library;

import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/companion/client/companion_gateway.dart';
import 'package:chitragupta/src/features/companion/client/remote_companion_gateway.dart';
import 'package:chitragupta/src/features/companion/client/secure_companion_store.dart';
import 'package:chitragupta/src/features/remote/application/remote_host_service.dart';
import 'package:chitragupta/src/features/remote/client/companion_store.dart'
    as stored;
import 'package:chitragupta/src/features/remote/data/paired_device_dao.dart';
import 'package:chitragupta/src/features/remote/domain/remote_payloads.dart';
import 'package:chitragupta/src/features/remote/protocol.dart';
import 'package:chitragupta/src/features/remote/transport/relay_transport.dart';
import 'package:chitragupta_relay/chitragupta_relay.dart';
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

  setUp(() async {
    db = AppDatabase.memory();
    dao = PairedDeviceDao(db);
    fake = FakeRemoteBindings()..addSession('s1');
    fake.transcripts['s1'] = [
      const RemoteTranscriptMessage(role: 'user', text: 'hello'),
    ];
    relay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    relayUri = Uri.parse('http://127.0.0.1:${relay.port}');
    // The phone's "keystore": the secure store over a plain map backend, so
    // the record's whole journey through SecureCompanionStore is real.
    phoneDisk = {};
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
      hostId: DeviceId.parse('11111111222222223333333344444444'),
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
      deviceName: 'Test phone',
      relayFactory: (relay, rendezvous) => RelayTransport(
        endpoint: RelayTransport.endpointFor(relay, rendezvous),
        backoff: fastBackoff(),
        heartbeat: const Duration(milliseconds: 500),
      )..start(),
      requestTimeout: const Duration(seconds: 2),
      helloTimeout: const Duration(seconds: 2),
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
      .timeout(const Duration(seconds: 15));

  Future<CompanionPairing> pairPhone(RemoteCompanionGateway gateway) async {
    final session = await service!.beginPairing(
      capabilities: CapabilitySet.all,
    );
    final paired = await gateway.pairWithQr(session.payload.encode());
    await session.done;
    await awaitLink(gateway, CompanionLinkState.connected);
    return paired;
  }

  Future<void> eventually(
    Future<bool> Function() check, {
    Duration timeout = const Duration(seconds: 10),
    String reason = 'condition',
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (await check()) return;
      if (DateTime.now().isAfter(deadline)) fail('never happened: $reason');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('the whole phone story over the relay: pair, watch, prompt, approve, '
      'revoke', () async {
    await startService();
    final gateway = makeGateway();

    // Unpaired seeds: null pairing, nothing granted.
    expect(await gateway.pairingStates.first, isNull);
    expect(gateway.capabilities, CapabilitySet.none);

    // Pair from the QR payload the desktop would paint.
    final paired = await pairPhone(gateway);
    expect(paired.hostName, 'TestHost');
    expect(paired.capabilities.has(Capability.approve), isTrue);
    expect(gateway.pairing, isNotNull);
    expect(
      phoneDisk[stored.CompanionPairing.storeKey],
      isNotNull,
      reason: 'the pairing record must land in the secure store',
    );

    // sessions.list through the real protocol, mapped to phone terms.
    final sessions = await gateway.listSessions();
    expect(sessions.single.id, 's1');
    expect(sessions.single.title, 'Fix the tests');
    expect(sessions.single.status, CompanionSessionStatus.working);

    // The transcript stream: history first, then the live append.
    final transcript = ItemQueue(gateway.transcript('s1'));
    expect([for (final m in await transcript.next) m.text], ['hello']);
    fake.transcripts['s1']!.add(
      const RemoteTranscriptMessage(role: 'agent', text: 'on it'),
    );
    await service!.pollTranscriptsNow();
    expect([for (final m in await transcript.next) m.text], ['hello', 'on it']);

    // prompt.send lands on the desktop's own send route.
    await gateway.sendPrompt('s1', 'carry on');
    expect(fake.prompts, [(sessionId: 's1', text: 'carry on')]);

    // approval.requested → verbatim evidence → approval.answer.
    final approvals = ItemQueue(gateway.pendingApproval('s1'));
    expect(await approvals.next, isNull);
    final attention = ItemQueue(gateway.attentionEvents);
    fake.approvals['s1'] = const RemoteApprovalRequest(
      sessionId: 's1',
      evidence: ['Run the tests?', '[y/n]'],
      approveLabel: 'Yes (enter)',
      denyLabel: 'No (esc)',
    );
    fake.sessions['s1'] = fake.sessions['s1']!.copyWith(
      attention: 'needs_approval',
    );
    await service!.notifyApprovalRequested('s1');
    final pending = (await approvals.next)!;
    expect(pending.evidence, ['Run the tests?', '[y/n]']);
    expect(pending.approveLabel, 'Yes (enter)');
    expect(pending.denyLabel, 'No (esc)');

    // The attention event fired and the session list wears the claim.
    final needsYou = await attention.next;
    expect(needsYou.kind, CompanionAttentionKind.needsYou);
    expect(needsYou.sessionId, 's1');
    await eventually(() async {
      final list = await gateway.watchSessions().first;
      return list.single.attention?.kind == CompanionAttentionKind.needsYou;
    }, reason: 'the summary shows needs-you attention');

    await gateway.answerApproval(
      's1',
      pending.id,
      CompanionApprovalDecision.approve,
    );
    expect(await approvals.next, isNull);

    // A session.changed attention transition becomes its own event.
    fake.sessions['s1'] = fake.sessions['s1']!.copyWith(attention: 'failed');
    await service!.notifySessionsChanged();
    final failed = await attention.next;
    expect(failed.kind, CompanionAttentionKind.failed);

    // Revoke on the host: the phone surfaces a readable refusal and a
    // disconnected link — not a crash, not silence.
    await service!.revoke(dao.getActive().single.id);
    await expectLater(
      gateway.sendPrompt('s1', 'again'),
      throwsA(
        isA<GatewayException>().having(
          (e) => e.message,
          'message',
          contains('unreachable'),
        ),
      ),
    );
    await awaitLink(gateway, CompanionLinkState.disconnected);
  });

  test(
    'unpair forgets the stored pairing and refuses further actions',
    () async {
      await startService();
      final gateway = makeGateway();
      await pairPhone(gateway);

      await gateway.unpair();

      expect(gateway.pairing, isNull);
      expect(gateway.link, CompanionLinkState.disconnected);
      expect(gateway.capabilities, CapabilitySet.none);
      expect(
        phoneDisk.containsKey(stored.CompanionPairing.storeKey),
        isFalse,
        reason: 'unpair must delete the record from the secure store',
      );
      await expectLater(
        gateway.listSessions(),
        throwsA(
          isA<GatewayException>().having(
            (e) => e.message,
            'message',
            contains('not paired'),
          ),
        ),
      );
    },
  );

  test('a stored pairing is picked up on launch and reconnects by '
      'itself', () async {
    await startService();
    final first = makeGateway();
    await pairPhone(first);
    await first.close();

    // A "relaunch": a fresh gateway over the same phone disk.
    final again = makeGateway();
    expect(
      await again.pairingStates
          .firstWhere((pairing) => pairing != null)
          .timeout(const Duration(seconds: 5)),
      isNotNull,
    );
    await awaitLink(again, CompanionLinkState.connected);
    expect((await again.listSessions()).single.id, 's1');
  });

  test('a capability the desktop withheld maps to a permission '
      'sentence', () async {
    await startService();
    final gateway = makeGateway();
    final session = await service!.beginPairing(
      capabilities: CapabilitySet.of(const [
        Capability.viewSessions,
        Capability.readTranscript,
      ]),
    );
    await gateway.pairWithQr(session.payload.encode());
    await session.done;
    await awaitLink(gateway, CompanionLinkState.connected);

    await expectLater(
      gateway.sendPrompt('s1', 'hi'),
      throwsA(
        isA<GatewayException>().having(
          (e) => e.message,
          'message',
          contains('permission'),
        ),
      ),
    );
  });

  test('a garbage QR payload is refused with a sentence and pairs '
      'nothing', () async {
    final gateway = makeGateway();
    await expectLater(
      gateway.pairWithQr('https://example.com/not-a-pairing'),
      throwsA(
        isA<PairingException>().having(
          (e) => e.message,
          'message',
          contains('not a Chitragupta pairing code'),
        ),
      ),
    );
    expect(gateway.pairing, isNull);
    expect(phoneDisk, isEmpty);
  });

  test(
    'the short-code path says plainly that this desktop is QR-only',
    () async {
      final gateway = makeGateway();
      await expectLater(
        gateway.pairWithCode('ABCD1234'),
        throwsA(
          isA<PairingException>().having(
            (e) => e.message,
            'message',
            contains('QR pairing only'),
          ),
        ),
      );
    },
  );

  test('a corrupt stored record boots the gateway unpaired, not '
      'crashed', () async {
    phoneDisk[stored.CompanionPairing.storeKey] = '{not json';
    final gateway = makeGateway();
    expect(await gateway.pairingStates.first, isNull);
    expect(gateway.link, CompanionLinkState.disconnected);
    expect(gateway.capabilities, CapabilitySet.none);
  });
}
