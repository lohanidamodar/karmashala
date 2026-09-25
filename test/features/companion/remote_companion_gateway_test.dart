/// The integration seam, end to end and in process: the real
/// [RemoteCompanionGateway] over the real [CompanionClient], through an
/// in-process relay, into the real [RemoteHostService] and [HostSessionApi]
/// over faked desktop bindings. No fake is load-bearing anywhere between the
/// gateway surface and the desktop's provider seams.
library;

import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala/src/features/companion/client/secure_companion_store.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/host.dart';
import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_remote/client.dart' as stored;
import 'package:karmashala_remote/client.dart' hide CompanionPairing;
import 'package:karmashala_store/devices.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:flutter_test/flutter_test.dart';

import '../remote/fake_bindings.dart';
import '../remote/transport_harness.dart';

/// A beacon group of this suite's own, so a real host on the LAN cannot leak
/// into it (the lan_beacon_test convention). The PORT is per test, from
/// [freeBeaconPort] — see there for why sharing one across a file is a flake.
final _lanGroup = InternetAddress('239.255.42.202');

void main() {
  late int lanPort;
  late AppDatabase db;
  late PairedDeviceDao dao;
  late FakeRemoteBindings fake;
  late RelayServer relay;
  late Uri relayUri;
  RemoteHostService? service;
  late Map<String, String> phoneDisk;
  // Every port makeScout's dialer was pointed at, in order. Carried into the
  // stranger assertion's failure message: "Expected 1, Actual 2" alone cost two
  // days, because it cannot say whether the second dial went to the same
  // stranger (a probe forward) or to a foreign one (another suite's beacon
  // leaking in).
  final dialledPorts = <int>[];
  late SecureCompanionStore store;
  final gateways = <RemoteCompanionGateway>[];

  setUp(() async {
    dialledPorts.clear();
    lanPort = await freeBeaconPort();
    db = AppDatabase.memory();
    dao = PairedDeviceDao(db);
    fake = FakeRemoteBindings()..addSession('s1');
    fake.transcripts['s1'] = [
      const RemoteTranscriptMessage(role: 'user', text: 'hello'),
    ];
    relay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    // `localhost`, not `127.0.0.1`, and the difference is load-bearing.
    // `_onLanSighting` declines to upgrade a relay link when the beacon
    // arrives from the very address the relay is served on — that is the
    // *embedded local* relay, where a "direct" socket would reach the same
    // machine over the same network for nothing, and re-dialling it on every
    // beacon is what used to drop the owner's local-relay link on a schedule.
    // This suite's beacon does arrive from 127.0.0.1 (it advertises over
    // loopback so the tests never touch the real network), so spelling the
    // relay the same way would make this look like that case. A relay the
    // phone reaches by name is what the scenario actually means: somewhere
    // else, with the desktop reachable directly beside it.
    relayUri = Uri.parse('http://localhost:${relay.port}');
    // The phone's "keystore": the secure store over a plain map backend, so
    // the record's whole journey through SecureCompanionStore is real.
    phoneDisk = {
      // The last resort in Loop 83's dial order is the phone's CONFIGURED
      // relay, which defaults to the public PopupBits one. Point it at this
      // suite's in-process relay so a failed re-dial never reaches the
      // internet from a test.
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

  RemoteCompanionGateway makeGateway({
    LanPathScout? lan,
    Future<({String token, String platform})?> Function()? pushTokenSource,
    void Function(String message)? onLog,
    CompanionDeviceKind deviceKind = CompanionDeviceKind.unknown,
  }) {
    final gateway = RemoteCompanionGateway(
      store: store,
      deviceModel: 'Test phone',
      deviceKind: deviceKind,
      lan: lan,
      pushTokenSource: pushTokenSource,
      onLog: onLog,
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

  LanPathScout makeScout() => LanPathScout(
    group: _lanGroup,
    beaconPort: lanPort,
    attemptTimeout: const Duration(milliseconds: 800),
    retryCooldown: const Duration(seconds: 30),
    // The beacon's source address is whatever interface multicast rode in
    // on; this suite's listeners sit on loopback, so dial there. Production
    // keeps the datagram's own address.
    dialer: (host, port) {
      dialledPorts.add(port);
      return LanTransport.dial(
        host: '127.0.0.1',
        port: port,
        connectTimeout: const Duration(milliseconds: 800),
        backoff: fastBackoff(),
      );
    },
  );

  Future<void> awaitLink(
    RemoteCompanionGateway gateway,
    CompanionLinkState wanted,
  ) => gateway.linkStates
      .firstWhere((state) => state == wanted)
      .timeout(const Duration(seconds: 60));

  Future<void> awaitPath(
    RemoteCompanionGateway gateway,
    CompanionLinkPath wanted,
  ) => gateway.linkPathStates
      .firstWhere((path) => path == wanted)
      .timeout(const Duration(seconds: 60));

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

  test(
    'the whole phone story over the relay: pair, watch, prompt, approve, '
    'revoke',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
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
      expect(
        [for (final m in await transcript.next) m.text],
        ['hello', 'on it'],
      );

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
      //
      // It says *revoked*, which it can only do because the host says so on the
      // way out. Over a relay the link outlives a revoke — the host closes its
      // runtime, the phone's relay socket does not — so without that frame this
      // request merely goes unanswered, and the phone would report a busy
      // desktop for a pairing that no longer exists.
      await service!.revoke(dao.getActive().single.id);
      await expectLater(
        gateway.sendPrompt('s1', 'again'),
        throwsA(
          isA<GatewayException>().having(
            (e) => e.message,
            'message',
            contains('revoked'),
          ),
        ),
      );
      await awaitLink(gateway, CompanionLinkState.disconnected);
    },
  );

  // The owner asked to be warned on the phone when a session hits its limit.
  // Claude Code ends such a turn as a failure first; the limit follows once
  // the desktop has read the account's usage.
  test(
    'a usage limit reaches the phone in the desktop\'s words, and the '
    'failure under it is not told twice',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      await startService();
      final gateway = makeGateway();
      await pairPhone(gateway);
      await gateway.listSessions();
      final attention = ItemQueue(gateway.attentionEvents);

      RemoteSessionSnapshot s1({String? usageLimit}) => RemoteSessionSnapshot(
        sessionId: 's1',
        title: 'Fix the tests',
        status: 'failed',
        attention: 'failed',
        usageLimit: usageLimit,
      );

      fake.sessions['s1'] = s1();
      await service!.notifySessionsChanged();
      expect((await attention.next).kind, CompanionAttentionKind.failed);

      const sentence = 'Claude Code hit its 5-hour limit. Resets 14:05.';
      fake.sessions['s1'] = s1(usageLimit: sentence);
      await service!.notifySessionsChanged();
      final limit = await attention.next;
      expect(limit.kind, CompanionAttentionKind.usageLimit);
      expect(limit.detail, sentence);
      await eventually(() async {
        final list = await gateway.watchSessions().first;
        return list.single.usageLimit == sentence &&
            list.single.attention?.kind == CompanionAttentionKind.usageLimit;
      }, reason: 'the inbox row wears the limit');

      // Looked at on the desktop: the limit is no longer news, and the failed
      // turn under it was told already.
      fake.sessions['s1'] = s1();
      await service!.notifySessionsChanged();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(attention.isEmpty, isTrue);
    },
  );

  test(
    'an approval answered on the desktop stops offering itself on the '
    'phone',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      // Seen on the owner's phone, 2026-09-02: the card below the chat kept
      // offering approve and deny for a decision the desktop had already made.
      // The protocol said when a request appeared and never when it went away.
      await startService();
      final gateway = makeGateway();
      await pairPhone(gateway);
      await gateway.listSessions();

      final approvals = ItemQueue(gateway.pendingApproval('s1'));
      expect(await approvals.next, isNull);
      final resolutions = ItemQueue(gateway.approvalResolutions);

      fake.approvals['s1'] = const RemoteApprovalRequest(
        sessionId: 's1',
        evidence: ['Run the tests?', '[y/n]'],
        approveLabel: 'Yes (enter)',
      );
      fake.setAwaitingApproval('s1');
      await service!.notifyApprovalRequested('s1');
      expect((await approvals.next)!.approveLabel, 'Yes (enter)');

      // Answered somewhere this phone cannot see — the desktop's own card, or a
      // second paired phone. All the host knows is that the session stopped
      // asking, which is exactly what it says.
      fake.setAwaitingApproval('s1', waiting: false);
      await service!.notifySessionsChanged();

      expect(await approvals.next, isNull);
      final resolution = await resolutions.next;
      expect(resolution.sessionId, 's1');
      expect(resolution.outcome, CompanionApprovalOutcome.elsewhere);

      // And the host is the arbiter: an answer this phone sends afterwards is
      // refused rather than typed into whatever prompt is there now.
      await expectLater(
        gateway.answerApproval('s1', 'a1', CompanionApprovalDecision.approve),
        throwsA(
          isA<GatewayException>().having(
            (e) => e.message,
            'message',
            contains('already been answered'),
          ),
        ),
      );
      expect(fake.approvalAnswers, isEmpty);
    },
  );

  test(
    'a session merely waiting for input crosses the wire as a notice, not '
    'an approval',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      // The host fires the same event for both — `needs_approval` means the
      // session has stopped for the user, which an agent sitting at its own
      // prompt has also done. What separates them is the wait kind, and the
      // keys that ride with it.
      await startService();
      final gateway = makeGateway();
      await pairPhone(gateway);
      await gateway.listSessions();

      final approvals = ItemQueue(gateway.pendingApproval('s1'));
      expect(await approvals.next, isNull);

      fake.approvals['s1'] = const RemoteApprovalRequest(
        sessionId: 's1',
        evidence: ['Claude is waiting for your input'],
        waiting: RemoteWaitKind.input,
      );
      fake.setAwaitingApproval('s1');
      await service!.notifyApprovalRequested('s1');

      final pending = (await approvals.next)!;
      expect(pending.waiting, RemoteWaitKind.input);
      // No key survives the crossing, so there is nothing for the card to press.
      expect(pending.approveLabel, isNull);
      expect(pending.denyLabel, isNull);
      // The agent's own words still do.
      expect(pending.evidence, ['Claude is waiting for your input']);
    },
  );

  test(
    'a transcript too long for one frame arrives with its top named',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      // The host answers with the tail and says how much it kept back; the
      // phone turns that count into the marker that opens its window, so a
      // conversation that begins mid-sentence never reads as a lost start.
      const extra = 12;
      fake.transcripts['s1'] = [
        for (var i = 0; i < kRemoteTranscriptPageMax + extra; i++)
          RemoteTranscriptMessage(role: 'agent', text: 'turn-$i'),
      ];
      await startService();
      final gateway = makeGateway();
      await pairPhone(gateway);

      final messages = await gateway.transcript('s1').first;
      expect(messages.length, kRemoteTranscriptPageMax + 1);
      expect(messages.first.role, kCompanionNoticeRole);
      expect(
        messages.first.text,
        startsWith('$extra earlier messages are not loaded'),
      );
      expect(messages[1].text, 'turn-$extra');
      expect(
        messages.last.text,
        'turn-${kRemoteTranscriptPageMax + extra - 1}',
      );
    },
  );

  test('an empty transcript arrives with the host\'s reason for it', () async {
    // "It shows running, but when I open it, it doesn't show any transcript."
    // Nothing was broken about the reading — Antigravity keeps no store this
    // app can parse — but an empty list said the same thing as a session that
    // had not spoken, so the phone hedged and drew a welcome over the answer.
    fake.transcripts['s1'] = const [];
    fake.absences['s1'] = RemoteTranscriptAbsence.noChatView;
    await startService();
    final gateway = makeGateway();
    await pairPhone(gateway);

    final messages = await gateway.transcript('s1').first;
    expect(messages.single.role, kCompanionAbsenceRole);
    // The wire carried the fact; the phone owns the sentence.
    expect(messages.single.text, contains('no chat view'));
    expect(messages.single.text, contains('still reach it'));
  });

  test(
    'a session whose store kept no transcript gets the other sentence',
    () async {
      // Same shape of refusal, different fact: this is about the conversation,
      // not the agent. The WSL Antigravity install keeps a transcript for all 25
      // of its conversations, so "this agent keeps none" is the wrong half of
      // the answer for a session that simply has no file beside its record.
      fake.transcripts['s1'] = const [];
      fake.absences['s1'] = RemoteTranscriptAbsence.noTranscriptFile;
      await startService();
      final gateway = makeGateway();
      await pairPhone(gateway);

      final messages = await gateway.transcript('s1').first;
      expect(messages.single.role, kCompanionAbsenceRole);
      expect(messages.single.text, contains('kept the conversation'));
      expect(messages.single.text, contains('no chat view'));
      expect(messages.single.text, contains('still reach it'));
      expect(messages.single.text, isNot(contains('This agent keeps')));
    },
  );

  // **The whole point of the new bit, end to end.** The phone asks, the host
  // answers from the read it already made, and the elapsed time is a duration
  // both ends agree on because both instants came off the desktop's clock.
  test(
    "what a session is doing crosses, measured on the host's clock",
    () async {
      final observed = DateTime.utc(2026, 9, 7, 12);
      fake.observedAt = observed;
      fake.activities['s1'] = RemoteSessionActivity(
        sessionId: 's1',
        observedAt: observed,
        calls: [
          RemoteActivityCall(
            summary: 'Agent(review the diff)',
            toolName: 'Agent',
            subagent: true,
            // 4,549,121 ms — one of the two subagent runs this feature exists
            // for, and more than twice the ceiling that used to hide it.
            startedAt: observed.subtract(const Duration(milliseconds: 4549121)),
          ),
        ],
      );
      await startService();
      final gateway = makeGateway();
      await pairPhone(gateway);

      final activity = await gateway
          .activity('s1')
          .firstWhere((reading) => reading.known);

      expect(activity.calls.single.summary, 'Agent(review the diff)');
      expect(activity.calls.single.subagent, isTrue);
      expect(
        activity.calls.single.elapsed,
        const Duration(milliseconds: 4549121),
      );
      expect(activity.absence, isNull);
    },
  );

  test('a pairing without view_activity is told so, not left empty', () async {
    fake.activities['s1'] = RemoteSessionActivity(
      sessionId: 's1',
      observedAt: DateTime.utc(2026, 9, 7, 12),
    );
    await startService();
    final gateway = makeGateway();
    final session = await service!.beginPairing(
      capabilities: CapabilitySet(
        CapabilitySet.all.bits & ~Capability.viewActivity.bit,
      ),
    );
    await gateway.pairWithQr(session.payload.encode());
    await session.done;
    await awaitLink(gateway, CompanionLinkState.connected);

    final activity = await gateway
        .activity('s1')
        .firstWhere((reading) => reading.known);

    expect(activity.refused, contains('view_activity'));
    expect(
      activity.calls,
      isEmpty,
      reason: 'and the screen shows the sentence, never the empty list',
    );
  });

  test('a transcript with turns carries no reason at all', () async {
    // A reason beside turns would be describing a transcript that exists.
    fake.absences['s1'] = RemoteTranscriptAbsence.noChatView;
    await startService();
    final gateway = makeGateway();
    await pairPhone(gateway);

    final messages = await gateway.transcript('s1').first;
    expect([for (final m in messages) m.role], ['user']);
  });

  test(
    'a revoked pairing says so, rather than blaming a busy desktop',
    () async {
      // A revoke and a slow desktop look identical on the wire: a request goes
      // out and nothing comes back. They must not read the same.
      //
      // The phone cannot tell them apart on its own, either — over a relay the
      // *link* outlives a revoke, since the host closes its runtime while the
      // phone's relay socket stays up. So the host says it outright on the way
      // out, and the sentence for everything still genuinely unknown stays
      // hedged rather than claiming the link is up.
      await startService();
      final gateway = makeGateway();
      await pairPhone(gateway);
      expect((await gateway.listSessions()).single.id, 's1');

      await service!.revoke(dao.getActive().single.id);

      await expectLater(
        gateway.sendPrompt('s1', 'and now?'),
        throwsA(
          isA<GatewayException>().having(
            (e) => e.message,
            'message',
            allOf(contains('revoked'), isNot(contains('busy'))),
          ),
        ),
      );
      await awaitLink(gateway, CompanionLinkState.disconnected);
    },
  );

  test('a refusal while the link is down re-dials instead of parking on '
      'it', () async {
    await startService();
    final gateway = makeGateway();
    await pairPhone(gateway);
    // Let the post-connect refresh finish: a request already in flight when
    // the host goes away wakes the loop by itself and would hide the gap
    // this test is about.
    expect((await gateway.listSessions()).single.id, 's1');
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // The desktop and its relay both go away, so the phone's transport keeps
    // re-dialling and the link reads "connecting" from here on.
    final blip = gateway.linkStates
        .firstWhere((state) => state == CompanionLinkState.connecting)
        .timeout(const Duration(seconds: 10));
    await service!.stop();
    await relay.close();
    await blip;

    // The refusal has to tell the connect loop the link is not what it
    // claims. Without that the gateway parks on the dead link for good — and
    // once the relay is back it reports "connected" on a rendezvous nobody
    // is listening on, so the phone never reconnects.
    await expectLater(
      gateway.sendPrompt('s1', 'anyone there?'),
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

  test('the workspace and a start, end to end over the relay', () async {
    fake.addWorkspace();
    await startService();
    final gateway = makeGateway();
    await pairPhone(gateway);

    final projects = await gateway.listWorkspace();
    expect(projects.single.projectId, 'p1');
    final checkout = projects.single.checkouts.single;
    final agent = checkout.agents.single;
    expect(agent.name, 'Claude Code');
    expect(agent.defaultMode, 'ask');
    expect(agent.permissionModes.first.label, 'Ask every time');

    final started = await gateway.startSession(
      requestId: 'k1',
      repositoryId: checkout.repositoryId,
      installationId: agent.installationId,
      permissionMode: 'bypass',
      title: 'From the phone',
      message: 'get started',
    );

    expect(started.title, 'From the phone');
    expect(started.replayed, isFalse);
    expect(fake.starts, hasLength(1));
    expect(fake.starts.single.permissionMode, 'bypass');
    expect(fake.starts.single.message, 'get started');
    expect(
      (await gateway.listSessions()).map((s) => s.id),
      contains(started.sessionId),
      reason: 'the phone can land on the session it just started',
    );
  });

  test('project add and session resume round-trip over the relay', () async {
    fake.addWorkspace();
    await startService();
    final gateway = makeGateway();
    await pairPhone(gateway);

    final before = await gateway.listProjects();
    expect(before.single.projectId, 'p1');
    final added = await gateway.addProject(
      requestId: 'project-1',
      name: 'New project',
      path: r'C:\work\new-project',
    );
    expect(added.name, 'New project');
    expect(fake.addProjectCalls, 1);

    final resumed = await gateway.resumeSession(
      requestId: 'resume-1',
      sessionId: 's1',
    );
    expect(resumed.sessionId, 's1');
    expect(fake.resumeCalls, 1);
  });

  test('a start resent after a re-dial costs one session, not two', () async {
    fake.addWorkspace();
    await startService();
    final first = makeGateway();
    await pairPhone(first);
    final started = await first.startSession(
      requestId: 'k1',
      repositoryId: 'r1',
      installationId: 'i1',
      permissionMode: 'ask',
      title: 'Only once',
    );
    // The answer never reached the phone and the app was relaunched: a fresh
    // gateway over the same phone disk, which dials a NEW generation and so
    // meets a brand-new HostSessionApi at the other end.
    await first.close();
    final again = makeGateway();
    await awaitLink(again, CompanionLinkState.connected);

    final retry = await again.startSession(
      requestId: 'k1',
      repositoryId: 'r1',
      installationId: 'i1',
      permissionMode: 'ask',
      title: 'Only once',
    );

    expect(fake.starts, hasLength(1), reason: 'one intention, one session');
    expect(retry.sessionId, started.sessionId);
    expect(retry.replayed, isTrue);
  });

  test('a desktop that refuses a start says why, in its own words', () async {
    fake
      ..addWorkspace()
      ..startError = const RemoteApiRefusal(
        ErrorCode.badRequest,
        'Antigravity takes no opening message on its command line',
      );
    await startService();
    final gateway = makeGateway();
    await pairPhone(gateway);

    await expectLater(
      gateway.startSession(
        requestId: 'k1',
        repositoryId: 'r1',
        installationId: 'i1',
        permissionMode: 'ask',
        message: 'go',
      ),
      throwsA(
        isA<GatewayException>().having(
          (e) => e.message,
          'message',
          contains('takes no opening message'),
        ),
      ),
    );
  });

  test('a phone without the start grant is refused both verbs', () async {
    fake.addWorkspace();
    await startService();
    final gateway = makeGateway();
    final session = await service!.beginPairing(
      capabilities: CapabilitySet(
        CapabilitySet.all.bits & ~Capability.startSession.bit,
      ),
    );
    await gateway.pairWithQr(session.payload.encode());
    await session.done;
    await awaitLink(gateway, CompanionLinkState.connected);

    expect(gateway.capabilities.has(Capability.startSession), isFalse);
    for (final refused in [
      gateway.listWorkspace(),
      gateway.startSession(
        requestId: 'k1',
        repositoryId: 'r1',
        installationId: 'i1',
        permissionMode: 'ask',
      ),
    ]) {
      await expectLater(
        refused,
        throwsA(
          isA<GatewayException>().having(
            (e) => e.message,
            'message',
            contains('permission'),
          ),
        ),
      );
    }
    expect(fake.starts, isEmpty);
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
          contains('not a Karmashala pairing code'),
        ),
      ),
    );
    expect(gateway.pairing, isNull);
    // Nothing about a pairing was written — the only key on this phone's
    // "disk" is the relay setting the suite seeded before any of this.
    expect(phoneDisk.keys, [RemoteCompanionGateway.kPairingRelayStoreKey]);
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
            contains('not a Karmashala pairing code'),
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

  test(
    'the LAN story: pair over the relay, see the beacon, switch to the '
    'direct path, lose it, heal back to the relay',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      await startService();
      final gateway = makeGateway(lan: makeScout());
      await pairPhone(gateway);
      expect(gateway.linkPath, CompanionLinkPath.relay);

      // The desktop appears on this network — its beacon points at a proxy in
      // front of the host's LAN listener, so the test can sever the LAN alone.
      final proxy = await _TcpProxy.start(service!.lanPortBound!);
      final beacon = await LanBeacon.advertise(
        port: proxy.port,
        tag: 'realhost00000001',
        interval: const Duration(milliseconds: 100),
        group: _lanGroup,
        beaconPort: lanPort,
        // Loopback, so the suite never advertises onto the real network — and
        // so it still works on macOS 15+, where multicast off-machine is denied
        // until a human grants Local Network access. See lan_beacon_test.dart.
        bindAddress: InternetAddress.loopbackIPv4,
      );
      addTearDown(beacon.stop);

      await awaitPath(gateway, CompanionLinkPath.lan);
      await awaitLink(gateway, CompanionLinkState.connected);

      // Traffic over the direct path reaches the same desktop bindings.
      await eventually(() async {
        try {
          await gateway.sendPrompt('s1', 'over the lan');
          return true;
        } on GatewayException {
          return false;
        }
      }, reason: 'a prompt goes through over the LAN');
      expect(fake.prompts, contains((sessionId: 's1', text: 'over the lan')));

      // The LAN dies — host left the network; its beacon goes quiet too.
      beacon.stop();
      await proxy.kill();

      await awaitPath(gateway, CompanionLinkPath.relay);
      await awaitLink(gateway, CompanionLinkState.connected);
      await eventually(() async {
        try {
          await gateway.sendPrompt('s1', 'healed to the relay');
          return true;
        } on GatewayException {
          return false;
        }
      }, reason: 'a prompt goes through after healing to the relay');
      expect(
        fake.prompts,
        contains((sessionId: 's1', text: 'healed to the relay')),
      );
    },
  );

  test(
    'a beacon is only a hint: a host that cannot seal is a stranger, '
    'and the relay carries the link',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      await startService();
      // A stranger advertising a socket that accepts and answers nothing. It
      // holds no paired key, so it can never produce the sealed host.status.
      final rogue = await ServerSocket.bind('127.0.0.1', 0);
      // What it accepts is HELD, and that is the whole difference between a
      // stranger that stays silent and one that hangs up. A `Socket` nobody
      // references is closed by the VM's finaliser the next time the GC runs,
      // and the phone reads that clean FIN as the far end letting go — which
      // `_dialLan` is right to treat as "a host one generation ahead", so it
      // probes forward and dials a second time. That is the second
      // `lan attempt failed` the assertion below used to trip over: six
      // sightings across 2026-09-02/03, always on a loaded machine, because a
      // busy machine is one that collects inside the 800ms hello window.
      final accepted = <Socket>[];
      rogue.listen(accepted.add);
      addTearDown(() {
        for (final socket in accepted) {
          socket.destroy();
        }
        return rogue.close();
      });
      final beacon = await LanBeacon.advertise(
        port: rogue.port,
        tag: 'rogue00000000001',
        interval: const Duration(milliseconds: 100),
        group: _lanGroup,
        beaconPort: lanPort,
        // Loopback, so the suite never advertises onto the real network — and
        // so it still works on macOS 15+, where multicast off-machine is denied
        // until a human grants Local Network access. See lan_beacon_test.dart.
        bindAddress: InternetAddress.loopbackIPv4,
      );
      addTearDown(beacon.stop);

      final log = <String>[];
      final scout = makeScout();
      // Count the stranger's beacons as the scout sees them. `sightings` is
      // broadcast and carries every advert — cooldown filtering happens above
      // it — so this counts what the machine actually delivered, which is the
      // unit the cooldown window below is measured in.
      var beaconsSeen = 0;
      final sightings = scout.sightings.listen((host) {
        if (host.port == rogue.port) beaconsSeen++;
      });
      addTearDown(sightings.cancel);
      final gateway = makeGateway(lan: scout, onLog: log.add);
      await pairPhone(gateway);

      // Wait for the stranger to be sighted, dialled and refused — the event
      // this test is about — rather than for a fixed two seconds to elapse.
      //
      // The old shape read the link after `sleep(2s)` and it flaked: the scout
      // is started lazily inside the connect loop, so the first sighting can
      // land at any point after `connected`. `eventually` below would then pass
      // on the link as it stood before any beacon had been heard, the sleep
      // would expire while the 800ms stranger dial was still in flight, and the
      // sample read `connecting`. That is the loop working exactly as designed,
      // reported as a regression — one of the reds that broke roughly six
      // full-suite runs, and one of those was misread as a real break.
      int strangerDials() =>
          log.where((line) => line.startsWith('lan attempt failed')).length;
      await eventually(
        () async => strangerDials() > 0,
        // Not bounded by anything this test controls; the test's own timeout is
        // the budget.
        timeout: const Duration(seconds: 60),
        reason: 'the stranger is dialled and refused',
      );

      // The last wall-clock dependency in this file, and it went the same way
      // as the `sleep(2s)` above it. The window used to be two real seconds,
      // which is ~20 beacons on an idle machine and far fewer on a loaded one —
      // so the assertion got weaker exactly when the suite was busy, which is
      // when it kept failing (Mac and Windows, main and a branch, never alone).
      // Count the beacons instead: twenty more of the stranger's adverts have
      // to be *observed*, and every one of them is an invitation to dial that
      // the cooldown had to decline.
      final beaconsAtFirstDial = beaconsSeen;
      await eventually(
        () async => beaconsSeen - beaconsAtFirstDial >= 20,
        // The test's own timeout is the budget; nothing here bounds it.
        timeout: const Duration(seconds: 60),
        reason: 'twenty more stranger beacons are observed',
      );
      expect(
        strangerDials(),
        1,
        reason:
            'the stranger is in cooldown, not in a dial loop; '
            'beacon group $_lanGroup port $lanPort, stranger port ${rogue.port}, '
            'beacons observed $beaconsSeen (from $beaconsAtFirstDial), '
            'dialled $dialledPorts, log $log',
      );

      await eventually(
        () async =>
            gateway.link == CompanionLinkState.connected &&
            gateway.linkPath == CompanionLinkPath.relay,
        reason: 'the relay carries the link past the stranger',
      );
      expect((await gateway.listSessions()).single.id, 's1');
    },
  );

  test('the list payload carries label, whereabouts, stage, activity and '
      'the imported flag through the real gateway', () async {
    fake.sessions.clear();
    fake.addSession(
      's1',
      agentLabel: 'Claude Code  ·  running',
      whereabouts: 'running here',
      lastActivityAt: '2026-08-31T10:05:00.000Z',
    );
    fake.addSession(
      'imp1',
      title: 'Old CLI chat',
      status: 'imported',
      agentLabel: 'Claude Code  ·  imported',
      imported: true,
    );
    fake.stages['s1'] = 'pushed';
    await startService();
    final gateway = makeGateway();
    await pairPhone(gateway);

    final sessions = await gateway.listSessions();

    final live = sessions.singleWhere((s) => !s.imported);
    expect(live.agentLabel, 'Claude Code  ·  running');
    expect(live.whereabouts, 'running here');
    expect(
      live.deliveryStage,
      'pushed',
      reason: 'the list pays the same stage lookup the desktop strip pays',
    );
    expect(live.lastActivityAt, DateTime.utc(2026, 8, 31, 10, 5));

    final imported = sessions.singleWhere((s) => s.imported);
    expect(imported.title, 'Old CLI chat');
    expect(imported.agentLabel, 'Claude Code  ·  imported');
    expect(
      imported.deliveryStage,
      isNull,
      reason: 'imported history has no delivery line',
    );
  });

  test('notifications.register reaches the host from the pluggable token '
      'source', () async {
    await startService();
    final gateway = makeGateway(
      pushTokenSource: () async => (token: 'tok-123', platform: 'android'),
    );
    await pairPhone(gateway);

    await eventually(
      () async => fake.pushes.isNotEmpty,
      reason: 'the token lands on the host store',
    );
    expect(fake.pushes.single.token, 'tok-123');
    expect(fake.pushes.single.platform, 'android');
  });

  test(
    'presence rides the same frame, one per change and never a tick',
    () async {
      await startService();
      final gateway = makeGateway(
        deviceKind: CompanionDeviceKind.phone,
        pushTokenSource: () async => (token: 'tok-123', platform: 'android'),
      );
      await pairPhone(gateway);
      await eventually(() async => fake.pushes.isNotEmpty);

      // Three reports, two of which change the answer.
      await gateway.reportVisibility(CompanionVisibility.background);
      await gateway.reportVisibility(CompanionVisibility.background);
      await gateway.reportFocusedSession('s1');

      await eventually(
        () async => fake.pushes.length == 3,
        reason: 'the connect registration, then one frame per change',
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        fake.pushes,
        hasLength(3),
        reason: 'a report that says nothing new sends nothing at all',
      );
      final last = fake.pushes.last.presence;
      expect(last.deviceKind, CompanionDeviceKind.phone);
      expect(last.visibility, CompanionVisibility.background);
      expect(last.focusedSessionId, 's1');
      // The token is on every one of them: presence is additive to the frame
      // that already existed, not a frame of its own.
      expect(fake.pushes.map((p) => p.token), everyElement('tok-123'));
    },
  );

  test('a withheld notifications grant skips registration without even '
      'asking for a token', () async {
    await startService();
    var asked = false;
    final gateway = makeGateway(
      pushTokenSource: () async {
        asked = true;
        return (token: 'tok-999', platform: 'android');
      },
    );
    final session = await service!.beginPairing(
      capabilities: CapabilitySet.of(const [
        Capability.viewSessions,
        Capability.sendPrompt,
      ]),
    );
    await gateway.pairWithQr(session.payload.encode());
    await session.done;
    await awaitLink(gateway, CompanionLinkState.connected);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(asked, isFalse);
    expect(fake.pushes, isEmpty);
  });

  test(
    'permissions edited on the desktop reach the phone on the pairing it '
    'already has',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      await startService();
      final gateway = makeGateway();
      final session = await service!.beginPairing(
        capabilities: CapabilitySet.of(const [Capability.viewSessions]),
      );
      final paired = await gateway.pairWithQr(session.payload.encode());
      await session.done;
      await awaitLink(gateway, CompanionLinkState.connected);
      expect(paired.capabilities.has(Capability.sendPrompt), isFalse);
      final device = dao.getAll().single;

      // Refused while it is not granted: enforcement is per frame.
      await expectLater(
        gateway.sendPrompt('s1', 'before'),
        throwsA(isA<GatewayException>()),
      );
      expect(fake.prompts, isEmpty);

      await service!.updateCapabilities(
        device.id,
        CapabilitySet.of(const [
          Capability.viewSessions,
          Capability.sendPrompt,
        ]),
      );

      // The phone hears it on the link it already holds — no new code, no
      // scan, and the screens that gate on the grant follow.
      await eventually(
        () async => gateway.capabilities.has(Capability.sendPrompt),
        reason: 'the phone hears its widened grant',
      );
      expect(gateway.pairing!.capabilities.has(Capability.sendPrompt), isTrue);
      await gateway.sendPrompt('s1', 'after');
      expect(fake.prompts, [(sessionId: 's1', text: 'after')]);

      // Same pairing throughout: same row, same key, same generation.
      final after = dao.getAll().single;
      expect(after.id, device.id);
      expect(after.deviceKey, device.deviceKey);
      expect(after.generation, device.generation);

      // And narrowing lands the same way.
      await service!.updateCapabilities(
        device.id,
        CapabilitySet.of(const [Capability.viewSessions]),
      );
      await eventually(
        () async => !gateway.capabilities.has(Capability.sendPrompt),
        reason: 'the phone hears its narrowed grant',
      );
      await expectLater(
        gateway.sendPrompt('s1', 'after the narrowing'),
        throwsA(isA<GatewayException>()),
      );
      expect(fake.prompts, [(sessionId: 's1', text: 'after')]);
    },
  );
}

/// Forwards TCP to the host's LAN listener so a test can kill the LAN leg —
/// listener and live sockets both — while the relay stays healthy.
class _TcpProxy {
  _TcpProxy._(this._server, this._target) {
    _server.listen(_accept);
  }

  static Future<_TcpProxy> start(int targetPort) async {
    final server = await ServerSocket.bind('127.0.0.1', 0);
    return _TcpProxy._(server, targetPort);
  }

  final ServerSocket _server;
  final int _target;
  final List<Socket> _sockets = [];

  int get port => _server.port;

  Future<void> _accept(Socket inbound) async {
    final Socket outbound;
    try {
      outbound = await Socket.connect('127.0.0.1', _target);
    } on Object {
      inbound.destroy();
      return;
    }
    _sockets
      ..add(inbound)
      ..add(outbound);
    inbound.listen(
      outbound.add,
      onDone: outbound.destroy,
      onError: (Object _) => outbound.destroy(),
    );
    outbound.listen(
      inbound.add,
      onDone: inbound.destroy,
      onError: (Object _) => inbound.destroy(),
    );
  }

  Future<void> kill() async {
    await _server.close();
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    _sockets.clear();
  }
}
