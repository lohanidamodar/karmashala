import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

/// A closed client dials nothing more.
///
/// `connect()` walks forward across the generation window when a relay takes
/// the socket and nobody answers, calling the relay factory once per
/// generation. `close()` used to detach without ending the attempt in flight,
/// so its hello waited out the timeout, was read as "no host at this
/// generation", and the next one was dialled — after the gateway had switched
/// desktops, unpaired, or been closed. Seen as relay dials landing in the next
/// test's counters.
void main() {
  test(
    'closing mid-dial ends connect at once and dials nothing more',
    () async {
      var dials = 0;
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
        relayFactory: (relay, rendezvous) {
          dials++;
          return _SilentTransport();
        },
      );

      final connecting = client.connect(
        helloTimeout: const Duration(seconds: 2),
      );
      // Let the first attempt reach its hello.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(dials, 1);

      // Listened to before the close: the close is what fails it.
      final ended = expectLater(connecting, throwsA(isA<RemoteApiException>()));
      final closedAt = DateTime.now();
      await client.close();
      await ended;
      expect(
        DateTime.now().difference(closedAt),
        lessThan(const Duration(milliseconds: 500)),
        reason: 'the attempt in flight ends with the close, not at its timeout',
      );

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(dials, 1, reason: 'no generation is dialled after close');
    },
  );

  test('a closed client refuses to connect', () async {
    var dials = 0;
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
      relayFactory: (relay, rendezvous) {
        dials++;
        return _SilentTransport();
      },
    );
    await client.close();
    await expectLater(client.connect(), throwsA(isA<RemoteApiException>()));
    expect(dials, 0);
  });
}

/// A relay that took the socket and has nobody behind it.
class _SilentTransport extends RemoteTransport {
  final _frames = StreamController<Uint8List>.broadcast();

  @override
  Stream<Uint8List> get frames => _frames.stream;

  @override
  Stream<TransportState> get states =>
      Stream<TransportState>.value(TransportState.connected);

  @override
  TransportState get state => TransportState.connected;

  @override
  void send(List<int> frame) {}

  @override
  Future<void> close() => _frames.close();
}
