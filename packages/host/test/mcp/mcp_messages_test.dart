import 'package:karmashala_host/protocol.dart';
import 'package:test/test.dart';

T _roundTrip<T extends HostMessage>(HostMessage message) {
  final frames = FrameParser().add(message.toFrame().encode());
  return decodeMessage(frames.single) as T;
}

void main() {
  test('the catalogue, a call and both answers survive the wire', () {
    final tools = _roundTrip<McpToolsMessage>(
      const McpToolsMessage([
        {'name': 'echo', 'inputSchema': <String, Object?>{}},
      ]),
    );
    expect(tools.tools.single['name'], 'echo');

    final call = _roundTrip<McpCallMessage>(
      const McpCallMessage(
        callId: 7,
        tool: 'session_wait',
        arguments: {'timeoutSeconds': 600},
        callerSessionId: 's1',
      ),
    );
    expect(call.callId, 7);
    expect(call.tool, 'session_wait');
    expect(call.arguments, {'timeoutSeconds': 600});
    expect(call.callerSessionId, 's1');

    final unattributed = _roundTrip<McpCallMessage>(
      const McpCallMessage(callId: 8, tool: 'echo', arguments: {}),
    );
    expect(unattributed.callerSessionId, isNull);

    final ok = _roundTrip<McpResultMessage>(
      const McpResultMessage.success(7, {'done': true}),
    );
    expect(ok.ok, isTrue);
    expect(ok.result, {'done': true});

    final failed = _roundTrip<McpResultMessage>(
      const McpResultMessage.failure(8, 'Bad state: boom'),
    );
    expect(failed.ok, isFalse);
    expect(failed.error, 'Bad state: boom');
  });
}
