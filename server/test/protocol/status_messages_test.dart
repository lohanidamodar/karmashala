import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

T roundTrip<T extends HostMessage>(T message) {
  final frames = FrameParser().add(message.toFrame().encode());
  expect(frames, hasLength(1));
  return decodeMessage(frames.single) as T;
}

/// Protocol 7: the daemon keeps what each hosted agent is doing and answers
/// its prompts. The status body is the agent-status package's JSON; the wire
/// only carries it.
void main() {
  test('the codes', () {
    expect(MessageType.agentStatus.code, 0x2b);
    expect(MessageType.promptAnswer.code, 0x2c);
    expect(MessageType.promptAnswered.code, 0x2d);
  });

  test('an agent status, and the word that it is no longer kept', () {
    final status = roundTrip(
      const AgentStatusMessage(
        sessionId: 'row-1',
        status: {
          'sessionId': 'row-1',
          'report': {'status': 'awaitingApproval'},
        },
      ),
    );
    expect(status.sessionId, 'row-1');
    expect((status.status!['report']! as Map)['status'], 'awaitingApproval');

    final gone = roundTrip(const AgentStatusMessage(sessionId: 'row-1'));
    expect(gone.status, isNull);
  });

  test('the watching snapshot carries the statuses', () {
    final watching = roundTrip(
      WatchingMessage(
        requestId: 2,
        observedAt: DateTime.utc(2026, 9, 25),
        sessions: const [],
        statuses: const [
          {'sessionId': 'row-1'},
        ],
      ),
    );
    expect(watching.statuses.single['sessionId'], 'row-1');
  });

  test('a prompt answer, and both of its endings', () {
    final asked = roundTrip(
      const PromptAnswerMessage(
        requestId: 9,
        request: {'kind': 'approval', 'sessionId': 'row-1', 'approve': true},
      ),
    );
    expect(asked.requestId, 9);
    expect(asked.request['approve'], true);

    final answered = roundTrip(
      const PromptAnsweredMessage.answered(
        requestId: 9,
        answered: 'Yes',
        effect: 'Chose "Yes"',
      ),
    );
    expect(answered.ok, isTrue);
    expect(answered.answered, 'Yes');

    final refused = roundTrip(
      const PromptAnsweredMessage.refused(
        requestId: 9,
        refusal: PromptRefusalKind.noTerminal,
        message: 'no live terminal',
      ),
    );
    expect(refused.ok, isFalse);
    expect(refused.refusal, PromptRefusalKind.noTerminal);
    expect(refused.message, 'no live terminal');
  });
}
