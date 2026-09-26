import 'package:karmashala_host/protocol.dart';
import 'package:test/test.dart';

T roundTrip<T extends HostMessage>(HostMessage message) {
  final frames = FrameParser().add(message.toFrame().encode());
  return decodeMessage(frames.single) as T;
}

void main() {
  test('the frames keep their numbers', () {
    expect(MessageType.serverCall.code, 0x30);
    expect(MessageType.serverResult.code, 0x31);
  });

  test('a call carries its method and arguments', () {
    final back = roundTrip<ServerCallMessage>(
      const ServerCallMessage(
        requestId: 12,
        method: ServerMethod.devicesRevoke,
        arguments: {'deviceId': 'ab12'},
      ),
    );
    expect(back.requestId, 12);
    expect(back.method, 'devices.revoke');
    expect(back.arguments, {'deviceId': 'ab12'});
  });

  test('an answer is a result or a refusal, never both', () {
    final ok = roundTrip<ServerResultMessage>(
      const ServerResultMessage.success(3, {
        'agents': [
          {'id': 'x'},
        ],
      }),
    );
    expect(ok.ok, isTrue);
    expect(ok.result, {
      'agents': [
        {'id': 'x'},
      ],
    });

    final refused = roundTrip<ServerResultMessage>(
      const ServerResultMessage.failure(4, 'no store'),
    );
    expect(refused.ok, isFalse);
    expect(refused.message, 'no store');
    expect(refused.result, isNull);
  });
}
