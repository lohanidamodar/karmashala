import 'dart:math';
import 'dart:typed_data';

import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

final _rendezvous = RendezvousId.parse('0123456789abcdef0123456789abcdef');

void main() {
  group('length-prefixed framing', () {
    test('a frame survives a round trip', () {
      final framer = LengthPrefixedFramer();
      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);

      final frames = framer.add(LengthPrefixedFramer.encode(payload));

      expect(frames, [payload]);
    });

    test('two frames in one chunk both come out', () {
      final framer = LengthPrefixedFramer();
      final chunk = <int>[
        ...LengthPrefixedFramer.encode([1]),
        ...LengthPrefixedFramer.encode([2, 3]),
      ];

      expect(framer.add(chunk), [
        [1],
        [2, 3],
      ]);
    });

    test('a frame split across chunks is reassembled', () {
      final framer = LengthPrefixedFramer();
      final encoded = LengthPrefixedFramer.encode([7, 8, 9, 10]);

      final out = <Uint8List>[];
      for (final byte in encoded) {
        out.addAll(framer.add([byte]));
      }

      expect(out, [
        [7, 8, 9, 10],
      ]);
    });

    test('a header split across chunks is reassembled', () {
      final framer = LengthPrefixedFramer();
      final encoded = LengthPrefixedFramer.encode([1, 2]);

      expect(framer.add(encoded.sublist(0, 2)), isEmpty);
      expect(framer.add(encoded.sublist(2)), [
        [1, 2],
      ]);
    });

    test('an empty frame is a frame', () {
      final framer = LengthPrefixedFramer();

      expect(framer.add(LengthPrefixedFramer.encode(const <int>[])), [isEmpty]);
    });

    test('a hundred frames in one chunk come out in order', () {
      final framer = LengthPrefixedFramer();
      final chunk = <int>[
        for (var i = 0; i < 100; i++) ...LengthPrefixedFramer.encode([i]),
      ];

      final frames = framer.add(chunk);

      expect(frames.length, 100);
      expect(
        frames.map((f) => f.single).toList(),
        List<int>.generate(100, (i) => i),
      );
    });

    test('a length over the cap is refused rather than buffered', () {
      final framer = LengthPrefixedFramer(maxFrameBytes: 16);
      final header = Uint8List(4);
      ByteData.view(header.buffer).setUint32(0, 1 << 20);

      expect(
        () => framer.add(header),
        throwsA(isA<TransportFramingException>()),
      );
    });

    test('a megabyte frame fits under the default cap', () {
      final framer = LengthPrefixedFramer();
      final payload = Uint8List(1024 * 1024);

      expect(
        framer.add(LengthPrefixedFramer.encode(payload)).single.length,
        payload.length,
      );
    });
  });

  group('backoff', () {
    test('grows and then stops growing', () {
      final backoff = Backoff(
        initial: const Duration(milliseconds: 100),
        maximum: const Duration(seconds: 2),
        jitter: 0,
        random: Random(1),
      );

      final delays = [
        for (var i = 0; i < 8; i++) backoff.next().inMilliseconds,
      ];

      expect(delays.take(5), [100, 200, 400, 800, 1600]);
      expect(delays.skip(5), everyElement(2000));
    });

    test('jitter stays inside its band', () {
      final backoff = Backoff(
        initial: const Duration(seconds: 1),
        maximum: const Duration(seconds: 1),
        jitter: 0.2,
        random: Random(7),
      );

      for (var i = 0; i < 50; i++) {
        final delay = backoff.next().inMilliseconds;
        expect(delay, inInclusiveRange(800, 1200));
      }
    });

    test('a successful connection resets it', () {
      final backoff = Backoff(
        initial: const Duration(milliseconds: 50),
        jitter: 0,
      );
      for (var i = 0; i < 5; i++) {
        backoff.next();
      }

      backoff.reset();

      expect(backoff.attempts, 0);
      expect(backoff.next().inMilliseconds, 50);
    });

    test('never returns a negative delay', () {
      final backoff = Backoff(
        initial: const Duration(milliseconds: 1),
        jitter: 1,
        random: Random(3),
      );

      for (var i = 0; i < 50; i++) {
        expect(backoff.next().inMicroseconds, greaterThanOrEqualTo(0));
      }
    });
  });

  group('the relay endpoint', () {
    test('is the rendezvous under /v1 on the relay', () {
      expect(
        RelayTransport.endpointFor(
          Uri.parse('wss://relay.popupbits.com'),
          _rendezvous,
        ).toString(),
        'wss://relay.popupbits.com/v1/0123456789abcdef0123456789abcdef',
      );
    });

    test('upgrades http and https to ws and wss', () {
      expect(
        RelayTransport.endpointFor(
          Uri.parse('https://relay.example'),
          _rendezvous,
        ).scheme,
        'wss',
      );
      expect(
        RelayTransport.endpointFor(
          Uri.parse('http://127.0.0.1:8787'),
          _rendezvous,
        ).scheme,
        'ws',
      );
    });

    test('keeps a port and a path prefix a self-hoster put in front', () {
      expect(
        RelayTransport.endpointFor(
          Uri.parse('https://example.com:8443/relay/'),
          _rendezvous,
        ).toString(),
        'wss://example.com:8443/relay/v1/0123456789abcdef0123456789abcdef',
      );
    });

    test('refuses a scheme that is not a relay', () {
      expect(
        () => RelayTransport.endpointFor(
          Uri.parse('ftp://relay.example'),
          _rendezvous,
        ),
        throwsA(isA<TransportException>()),
      );
    });
  });
}
