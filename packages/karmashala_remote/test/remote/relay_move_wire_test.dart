import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

/// The phone's half of `link.relay.move` at rest and on the wire: the hello
/// that says it knows the frame, and the relay it was moved to, dialled first.
void main() {
  final rendezvous = RendezvousId.parse('ab' * RendezvousId.lengthInBytes);

  group('LinkHello', () {
    test('a hello with no features is byte for byte what it was', () {
      expect(jsonDecode(utf8.decode(LinkHello(rendezvous).encode())), {
        'karmashala': 'link',
        'r': rendezvous.value,
      });
    });

    test('features round-trip, and an older hello reads as none', () {
      final hello = LinkHello.tryDecode(
        LinkHello(rendezvous, features: {kLinkFeatureRelayMove}).encode(),
      )!;
      expect(hello.features, {kLinkFeatureRelayMove});
      expect(
        LinkHello.tryDecode(LinkHello(rendezvous).encode())!.features,
        isEmpty,
      );
    });
  });

  group('the relay a pairing was moved to', () {
    final oldRelay = Uri.parse('wss://old.example.org');
    final newRelay = Uri.parse('wss://new.example.org');
    final now = DateTime.utc(2026, 10, 6, 12);

    test('is dialled first, ahead of a relay that worked more recently', () {
      final order = orderRelayCandidates(
        [
          RelayCandidate(url: oldRelay, lastSuccessAt: now),
          RelayCandidate(url: newRelay),
        ],
        fallback: oldRelay,
        now: now,
        preferred: newRelay,
      );
      expect(order, [newRelay, oldRelay]);
    });

    test('waits its turn while it cools from a failure', () {
      final order = orderRelayCandidates(
        [
          RelayCandidate(url: oldRelay, lastSuccessAt: now),
          RelayCandidate(url: newRelay, lastFailureAt: now),
        ],
        fallback: oldRelay,
        now: now,
        preferred: newRelay,
      );
      expect(order, [oldRelay]);
    });

    test('is kept with the record, and a record from before it has none', () {
      final record = CompanionPairing(
        hostId: DeviceId.parse('1' * 32),
        deviceId: DeviceId.parse('2' * 32),
        deviceKey: Uint8List(32),
        capabilities: CapabilitySet.all,
        relay: newRelay,
        relayHome: newRelay,
        generation: 4,
        hostName: 'desk',
      );
      final json = record.toJson();
      expect(CompanionPairing.fromJson(json).relayHome, newRelay);
      expect(
        CompanionPairing.fromJson({...json}..remove('home')).relayHome,
        isNull,
      );
    });
  });
}
