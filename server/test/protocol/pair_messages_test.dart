import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

/// The same round trip the rest of the protocol suite uses: encode, parse it
/// back off a byte stream, decode.
T roundTrip<T extends HostMessage>(T message) {
  final frames = FrameParser().add(message.toFrame().encode());
  return decodeMessage(frames.single) as T;
}

void main() {
  group('the pair messages survive the wire', () {
    test('a request carries the grant and the relay', () {
      const sent = PairMessage(requestId: 7, capabilities: 0x2a, relay: '');

      final back = roundTrip(sent);

      expect(back.requestId, 7);
      expect(back.capabilities, 0x2a);
      expect(
        back.relay,
        isEmpty,
        reason: 'a box with its own address needs none',
      );
      expect(back.relayIsLocal, isFalse);
    });

    test('a request says when its relay is the app\'s own', () {
      const sent = PairMessage(
        requestId: 8,
        capabilities: 1,
        relay: 'ws://192.168.1.4:8787',
        relayIsLocal: true,
      );

      final back = roundTrip(sent);

      expect(back.relay, sent.relay);
      expect(back.relayIsLocal, isTrue);
    });

    test('a request carries the name the paired device is given '
        '(protocol 8)', () {
      final back = roundTrip(
        const PairMessage(requestId: 9, capabilities: 1, label: 'Work phone'),
      );
      expect(back.label, 'Work phone');
      expect(
        roundTrip(const PairMessage(requestId: 9, capabilities: 1)).label,
        isEmpty,
      );
    });

    test('an answer carries the code and when it stops working', () {
      final sent = PairedMessage(
        requestId: 7,
        code: 'K7QM-3X2W-ABCD-EFGH-2345-6789-JKLM-NPQR',
        expiresAt: DateTime.utc(2026, 9, 16, 12, 30),
        payload: '{"v":1}',
      );

      final back = roundTrip(sent);

      expect(back.code, sent.code);
      expect(back.expiresAt, sent.expiresAt);
      expect(back.payload, sent.payload, reason: 'what the dialog draws');
    });
  });

  group('the codes', () {
    test('keep their numbers', () {
      expect(MessageType.pair.code, 0x12);
      expect(MessageType.paired.code, 0x13);
      expect(MessageType.fromCode(0x12), MessageType.pair);
      expect(MessageType.fromCode(0x99), isNull);
    });

    test('the protocol version is pinned, so moving it is a decision', () {
      // Protocol 8: a standalone server administered from its own machine
      // (serverCall, serverResult) and `pair` carrying a label. Protocol 9: a
      // forwarded `session.start` may ask for a worktree of its own.
      expect(kProtocolVersion, 31);
    });
  });

  group('a host with no store', () {
    test(
      'refuses to pair by name rather than failing at the ceremony',
      () async {
        // No companion is a `serve` whose SQLite would not load. It still owns
        // every PTY on the machine, so it serves sessions and says plainly
        // that this one thing is unavailable.
        final server = HostServer(
          registry: SessionRegistry(launcher: FakePtyLauncher()),
          ptyLibrary: 'fake',
        );

        expect(server.companion, isNull);
      },
    );
  });
}
