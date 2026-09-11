import 'dart:typed_data';

import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

/// One failed send must cost that request and nothing after it.
void main() {
  test('a send that throws fails its own request and leaves the chain usable',
      () async {
    final transport = _ThrowingTransport();
    final client = CompanionClient(
      pairing: CompanionPairing(
        hostId: DeviceId.parse('11111111222222223333333344444444'),
        deviceId: DeviceId.parse('aaaaaaaabbbbbbbbccccccccdddddddd'),
        deviceKey: Uint8List(32),
        capabilities: CapabilitySet.all,
        relay: Uri.parse('wss://relay.example.com'),
        generation: 1,
        hostName: 'Desk',
      ),
      store: InMemoryCompanionStore(),
    );
    // The link hello is the first send to throw; the client stays attached.
    await expectLater(
      client.connect(
        transport: transport,
        helloTimeout: const Duration(milliseconds: 200),
      ),
      throwsA(isA<TransportException>()),
    );

    await expectLater(
      client.registerNotifications(token: 't', platform: 'android'),
      throwsA(isA<TransportException>()),
    );
    // Used to replay the first failure without ever reaching the transport.
    await expectLater(
      client.registerNotifications(token: 't', platform: 'android'),
      throwsA(isA<TransportException>()),
    );
    expect(transport.sends, 3);
    await client.close();
  });
}

class _ThrowingTransport extends RemoteTransport {
  int sends = 0;

  @override
  Stream<Uint8List> get frames => const Stream<Uint8List>.empty();

  @override
  Stream<TransportState> get states =>
      Stream<TransportState>.value(TransportState.connected);

  @override
  TransportState get state => TransportState.connected;

  @override
  void send(List<int> frame) {
    sends++;
    throw const TransportException('the link is gone');
  }

  @override
  Future<void> close() async {}
}
