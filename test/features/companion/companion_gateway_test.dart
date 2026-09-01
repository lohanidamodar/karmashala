import 'package:karmashala/src/features/companion/client/companion_gateway.dart';
import 'package:karmashala/src/features/companion/client/fake_companion_gateway.dart';
import 'package:karmashala/src/features/remote/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// The scripted gateway the whole companion UI is built against. These pin the
/// contract the orchestrator wires Loop 70's real client behind: streams seed
/// with the current value, actions are refused with a user-fit sentence when
/// unpaired or unreachable, and pairing flips every derived state at once.
void main() {
  CompanionSessionSummary session(String id, {CompanionAttention? attention}) =>
      CompanionSessionSummary(
        id: id,
        title: 'Session $id',
        agentLabel: 'Claude Code  ·  running',
        projectName: 'popupbits',
        attention: attention,
      );

  group('pairing', () {
    test('starts unpaired with nothing granted', () {
      final gateway = FakeCompanionGateway();
      expect(gateway.pairing, isNull);
      expect(gateway.link, CompanionLinkState.disconnected);
      expect(gateway.capabilities, CapabilitySet.none);
    });

    test('a valid short code pairs and connects, case-insensitively', () async {
      final gateway = FakeCompanionGateway(validShortCode: 'ABCD1234');
      final paired = await gateway.pairWithCode('abcd1234');
      expect(paired.capabilities.has(Capability.sendPrompt), isTrue);
      expect(gateway.pairing, isNotNull);
      expect(gateway.link, CompanionLinkState.connected);
    });

    test('a wrong short code refuses with a sentence, and stays unpaired', () {
      final gateway = FakeCompanionGateway(validShortCode: 'ABCD1234');
      expect(
        () => gateway.pairWithCode('WRONG000'),
        throwsA(
          isA<PairingException>().having(
            (e) => e.message,
            'message',
            contains('did not recognise'),
          ),
        ),
      );
      expect(gateway.pairing, isNull);
    });

    test('a QR payload must be the pairing JSON', () async {
      final gateway = FakeCompanionGateway();
      expect(
        () => gateway.pairWithQr('https://example.com/not-a-pairing'),
        throwsA(isA<PairingException>()),
      );
      final paired = await gateway.pairWithQr(
        '{"relay":"wss://r","rendezvous":"ab","version":1,"secret":"s3cret"}',
      );
      expect(paired, same(gateway.pairing));
    });

    test('pairing states seed the current value on listen', () async {
      final gateway = FakeCompanionGateway();
      expect(await gateway.pairingStates.first, isNull);
      await gateway.pairWithCode(gateway.validShortCode);
      expect(await gateway.pairingStates.first, isNotNull);
    });

    test('unpair forgets the host and drops the link', () async {
      final gateway = FakeCompanionGateway.paired();
      await gateway.unpair();
      expect(gateway.pairing, isNull);
      expect(gateway.link, CompanionLinkState.disconnected);
    });
  });

  group('sessions and transcripts', () {
    test('watchSessions seeds the scripted list and follows changes', () async {
      final gateway = FakeCompanionGateway.paired(sessions: [session('s1')]);
      final seen = <List<CompanionSessionSummary>>[];
      final sub = gateway.watchSessions().listen(seen.add);
      await Future<void>.delayed(Duration.zero);
      gateway.setSessions([session('s1'), session('s2')]);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(seen.first.map((s) => s.id), ['s1']);
      expect(seen.last.map((s) => s.id), ['s1', 's2']);
    });

    test('sendPrompt records the call and appends the user turn', () async {
      final gateway = FakeCompanionGateway.paired(sessions: [session('s1')]);
      await gateway.sendPrompt('s1', 'run the tests');
      expect(gateway.sentPrompts, [(sessionId: 's1', text: 'run the tests')]);
      expect((await gateway.transcript('s1').first).last.text, 'run the tests');
    });

    test('sendPrompt refuses while the host is unreachable', () {
      final gateway = FakeCompanionGateway.paired(
        link: CompanionLinkState.disconnected,
      );
      expect(
        () => gateway.sendPrompt('s1', 'hello'),
        throwsA(
          isA<GatewayException>().having(
            (e) => e.message,
            'message',
            contains('unreachable'),
          ),
        ),
      );
      expect(gateway.sentPrompts, isEmpty);
    });

    test(
      'answerApproval records the decision and clears the approval',
      () async {
        final gateway = FakeCompanionGateway.paired(
          approvals: {
            's1': const CompanionApproval(
              id: 'a1',
              sessionId: 's1',
              agentName: 'Claude Code',
              approveLabel: 'Approve',
            ),
          },
        );
        expect(await gateway.pendingApproval('s1').first, isNotNull);
        await gateway.answerApproval(
          's1',
          'a1',
          CompanionApprovalDecision.approve,
        );
        expect(gateway.answeredApprovals.single.approvalId, 'a1');
        expect(await gateway.pendingApproval('s1').first, isNull);
      },
    );
  });

  group('link path', () {
    test('unpaired means no path; pairing connects over the relay', () async {
      final gateway = FakeCompanionGateway();
      expect(gateway.linkPath, isNull);
      expect(await gateway.linkPathStates.first, isNull);

      await gateway.pairWithCode(gateway.validShortCode);

      expect(gateway.linkPath, CompanionLinkPath.relay);
    });

    test(
      'linkPathStates seed the current value and follow the lever',
      () async {
        final gateway = FakeCompanionGateway.paired(
          linkPath: CompanionLinkPath.lan,
        );
        expect(await gateway.linkPathStates.first, CompanionLinkPath.lan);

        gateway.setLinkPath(CompanionLinkPath.relay);

        expect(gateway.linkPath, CompanionLinkPath.relay);
      },
    );

    test('a dropped link clears the path; unpair clears it too', () async {
      final gateway = FakeCompanionGateway.paired();
      expect(gateway.linkPath, CompanionLinkPath.relay);

      gateway.setLink(CompanionLinkState.disconnected);
      expect(gateway.linkPath, isNull);

      gateway.setLink(CompanionLinkState.connected);
      expect(gateway.linkPath, CompanionLinkPath.relay);

      await gateway.unpair();
      expect(gateway.linkPath, isNull);
    });

    test('the two paths carry the words the settings screen shows', () {
      expect(CompanionLinkPath.lan.label, 'Direct (LAN)');
      expect(CompanionLinkPath.relay.label, 'Relay');
    });
  });

  group('payload richness', () {
    test('a summary carries stage and the imported flag through copyWith', () {
      const summary = CompanionSessionSummary(
        id: 'imp1',
        title: 'old chat',
        agentLabel: 'Claude Code  ·  imported',
        projectName: 'popupbits',
        whereabouts: 'running here',
        deliveryStage: 'pushed',
        imported: true,
      );

      final stamped = summary.copyWith(
        status: CompanionSessionStatus.needsYou,
        attention: CompanionAttention(
          kind: CompanionAttentionKind.needsYou,
          at: DateTime.utc(2026, 8, 31, 12),
        ),
      );

      expect(stamped.deliveryStage, 'pushed');
      expect(stamped.imported, isTrue);
      expect(stamped.whereabouts, 'running here');
      expect(stamped.agentLabel, 'Claude Code  ·  imported');
      expect(stamped.status, CompanionSessionStatus.needsYou);
    });
  });

  group('connections', () {
    test('an unpaired phone holds no connections', () async {
      final gateway = FakeCompanionGateway();
      expect(gateway.connections, isEmpty);
      expect(await gateway.connectionsStates.first, isEmpty);
    });

    test('pairing ADDS a desktop and makes it active, keeping the ones '
        'already saved', () async {
      final gateway = FakeCompanionGateway();
      await gateway.pairWithCode(gateway.validShortCode);
      expect(gateway.connections, hasLength(1));
      expect(gateway.connections.single.active, isTrue);

      await gateway.pairWithCode(gateway.validShortCode);

      expect(gateway.connections, hasLength(2));
      expect(
        gateway.connections.where((c) => c.active).length,
        1,
        reason: 'exactly one desktop carries the link',
      );
      expect(gateway.connections.last.active, isTrue);
    });

    test('switchTo makes another desktop active', () async {
      final gateway = FakeCompanionGateway.paired(
        connections: [
          CompanionConnection(hostId: 'h1', name: 'One', active: true),
          const CompanionConnection(hostId: 'h2', name: 'Two', active: false),
        ],
      );

      await gateway.switchTo('h2');

      expect(gateway.connections.singleWhere((c) => c.active).hostId, 'h2');
      expect(gateway.pairing?.hostName, 'Two');
    });

    test('switchTo a desktop this phone does not hold is refused with a '
        'sentence', () {
      final gateway = FakeCompanionGateway.paired(
        connections: [
          const CompanionConnection(hostId: 'h1', name: 'One', active: true),
        ],
      );
      expect(
        () => gateway.switchTo('nope'),
        throwsA(
          isA<GatewayException>().having(
            (e) => e.message,
            'message',
            contains('no longer saved'),
          ),
        ),
      );
    });

    test('removeConnection drops one desktop; removing the active one falls '
        'back, and removing the last unpairs', () async {
      final gateway = FakeCompanionGateway.paired(
        connections: [
          const CompanionConnection(hostId: 'h1', name: 'One', active: true),
          const CompanionConnection(hostId: 'h2', name: 'Two', active: false),
        ],
      );

      await gateway.removeConnection('h1');
      expect(gateway.connections.single.hostId, 'h2');
      expect(gateway.connections.single.active, isTrue);
      expect(gateway.pairing, isNotNull);

      await gateway.removeConnection('h2');
      expect(gateway.connections, isEmpty);
      expect(gateway.pairing, isNull);
      expect(gateway.link, CompanionLinkState.disconnected);
    });

    test('connectionsStates seed the current value on listen', () async {
      final gateway = FakeCompanionGateway.paired(
        connections: [
          const CompanionConnection(hostId: 'h1', name: 'One', active: true),
        ],
      );
      expect((await gateway.connectionsStates.first).single.name, 'One');
    });

    test('a switch rebuilds the session list for the new desktop', () async {
      final gateway = FakeCompanionGateway.paired(
        sessions: [session('s-one')],
        connections: [
          const CompanionConnection(hostId: 'h1', name: 'One', active: true),
          const CompanionConnection(hostId: 'h2', name: 'Two', active: false),
        ],
        sessionsByHost: {
          'h2': [session('s-two')],
        },
      );

      await gateway.switchTo('h2');

      expect(
        (await gateway.watchSessions().first).map((s) => s.id),
        ['s-two'],
        reason: "no session from the old desktop survives the switch",
      );
    });
  });

  group('attention', () {
    test('emitAttention delivers the event and stamps the session', () async {
      final gateway = FakeCompanionGateway.paired(sessions: [session('s1')]);
      final events = <CompanionAttentionEvent>[];
      final sub = gateway.attentionEvents.listen(events.add);
      gateway.emitAttention(
        CompanionAttentionEvent(
          sessionId: 's1',
          sessionTitle: 'Session s1',
          kind: CompanionAttentionKind.needsYou,
          at: DateTime.utc(2026, 8, 31, 12),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(events.single.kind, CompanionAttentionKind.needsYou);
      final updated = (await gateway.watchSessions().first).single;
      expect(updated.attention?.kind, CompanionAttentionKind.needsYou);
      expect(updated.status, CompanionSessionStatus.needsYou);
    });
  });
}
