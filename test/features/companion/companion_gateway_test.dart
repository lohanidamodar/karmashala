import 'package:chitragupta/src/features/companion/client/companion_gateway.dart';
import 'package:chitragupta/src/features/companion/client/fake_companion_gateway.dart';
import 'package:chitragupta/src/features/remote/protocol.dart';
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
