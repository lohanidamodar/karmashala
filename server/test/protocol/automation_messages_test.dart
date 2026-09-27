import 'package:karmashala_host/protocol.dart';
import 'package:test/test.dart';

T roundTrip<T extends HostMessage>(HostMessage message) {
  final frames = FrameParser().add(message.toFrame().encode());
  return decodeMessage(frames.single) as T;
}

void main() {
  test('protocol 5 carries automations (7: agent status and answers; 8: '
      'server administration; 9: a start may ask a worktree; 10: the app\'s '
      'attach and the server config)', () {
    expect(kProtocolVersion, 20);
  });

  test('a notice says which kind', () {
    for (final kind in AutomationNoticeKind.values) {
      expect(
        roundTrip<AutomationNoticeMessage>(AutomationNoticeMessage(kind)).kind,
        kind,
      );
    }
  });

  test('a forwarded call keeps its occurrence and its queued row', () {
    final due = DateTime.utc(2026, 9, 25, 3);
    final call = roundTrip<AutomationCallMessage>(
      AutomationCallMessage(
        callId: 4,
        kind: AutomationCallKind.fireAutomation,
        id: 'auto1',
        note: 'caught up',
        scheduledFor: due,
        queuedRunId: 'run9',
      ),
    );
    expect(call.callId, 4);
    expect(call.kind, AutomationCallKind.fireAutomation);
    expect(call.id, 'auto1');
    expect(call.note, 'caught up');
    expect(call.scheduledFor, due);
    expect(call.queuedRunId, 'run9');

    final bare = roundTrip<AutomationCallMessage>(
      const AutomationCallMessage(
        callId: 5,
        kind: AutomationCallKind.fireResume,
        id: 'r1',
      ),
    );
    expect(bare.scheduledFor, isNull);
    expect(bare.queuedRunId, isNull);
  });

  test('a result is done or says why not', () {
    expect(
      roundTrip<AutomationResultMessage>(
        const AutomationResultMessage.success(3),
      ).ok,
      isTrue,
    );
    final failed = roundTrip<AutomationResultMessage>(
      const AutomationResultMessage.failure(3, 'no such automation'),
    );
    expect(failed.ok, isFalse);
    expect(failed.message, 'no such automation');
  });

  test('checks are asked for and answered', () {
    final asked = roundTrip<ChecksRunMessage>(
      const ChecksRunMessage(requestId: 9, sessionId: 's1'),
    );
    expect((asked.requestId, asked.sessionId), (9, 's1'));
    final ran = roundTrip<ChecksRanMessage>(
      const ChecksRanMessage(
        requestId: 9,
        outcome: ChecksRunOutcome.ran,
        verificationRunId: 'run-1',
      ),
    );
    expect(ran.outcome, ChecksRunOutcome.ran);
    expect(ran.verificationRunId, 'run-1');
  });
}
