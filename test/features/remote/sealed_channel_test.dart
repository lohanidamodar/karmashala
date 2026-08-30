import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chitragupta/src/features/remote/protocol.dart';
import 'package:chitragupta/src/features/remote/transport/key_schedule.dart';
import 'package:chitragupta/src/features/remote/transport/sealed_channel.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

final _secret = Uint8List.fromList(List<int>.generate(32, (i) => i));
final _hostId = DeviceId.parse('11111111222222223333333344444444');
final _deviceId = DeviceId.parse('aaaaaaaabbbbbbbbccccccccdddddddd');

Future<SecretKeyData> _deviceKey({DeviceId? deviceId}) => deriveDeviceKey(
  pairingSecret: _secret,
  hostId: _hostId,
  deviceId: deviceId ?? _deviceId,
);

/// A host and a companion channel over the same device key.
Future<(SealedChannel, SealedChannel)> _pair({int generation = 0}) async {
  final key = await _deviceKey();
  return (
    await SealedChannel.forDevice(
      deviceKey: key,
      role: ChannelRole.host,
      generation: generation,
    ),
    await SealedChannel.forDevice(
      deviceKey: key,
      role: ChannelRole.companion,
      generation: generation,
    ),
  );
}

void main() {
  group('sealing', () {
    test('a frame the host seals is what the companion opens', () async {
      final (host, companion) = await _pair();
      final message = utf8.encode('{"v":1,"seq":0,"t":"host.status","p":{}}');

      final opened = await companion.unseal(await host.seal(message));

      expect(opened.plaintext, message);
      expect(opened.sequence, 0);
    });

    test('and the other way round', () async {
      final (host, companion) = await _pair();
      final message = utf8.encode('prompt');

      final opened = await host.unseal(await companion.seal(message));

      expect(opened.plaintext, message);
    });

    test('the sequence counts up per direction', () async {
      final (host, companion) = await _pair();

      expect(host.nextSendSequence, 0);
      for (var i = 0; i < 5; i++) {
        final opened = await companion.unseal(await host.seal([i]));
        expect(opened.sequence, i);
      }
      expect(host.nextSendSequence, 5);
      expect(companion.highestReceivedSequence, 4);
      expect(
        companion.nextSendSequence,
        0,
        reason: 'the other direction has its own counter',
      );
    });

    test('an empty payload round-trips', () async {
      final (host, companion) = await _pair();

      final opened = await companion.unseal(await host.seal(const <int>[]));

      expect(opened.plaintext, isEmpty);
    });

    test('a megabyte round-trips', () async {
      final (host, companion) = await _pair();
      final big = Uint8List.fromList(
        List<int>.generate(1024 * 1024, (i) => i & 0xff),
      );

      final opened = await companion.unseal(await host.seal(big));

      expect(opened.plaintext.length, big.length);
      expect(opened.plaintext.sublist(0, 32), big.sublist(0, 32));
    });

    test('the frame is nonce, ciphertext and tag, and nothing else', () async {
      final (host, _) = await _pair();
      final message = utf8.encode('hello');

      final frame = await host.seal(message);

      expect(frame.length, message.length + kSealedFrameOverhead);
    });

    test('the plaintext never appears in the frame', () async {
      final (host, _) = await _pair();
      final secretText = 'ATTENTION-THE-DEPLOY-KEY-IS-HERE';

      final frame = await host.seal(utf8.encode(secretText));

      expect(
        String.fromCharCodes(frame).contains(secretText),
        isFalse,
        reason: 'the relay must not be able to read it',
      );
      expect(latin1.decode(frame, allowInvalid: true), isNot(contains('THE')));
    });

    test('a nonce is not reused across frames', () async {
      final (host, _) = await _pair();

      final nonces = <String>{};
      for (var i = 0; i < 32; i++) {
        final frame = await host.seal([i]);
        nonces.add(base64Encode(frame.sublist(0, kNonceBytes)));
      }

      expect(nonces.length, 32);
    });
  });

  group('what a channel refuses', () {
    test(
      'a frame it sealed itself — the directions have separate keys',
      () async {
        final (host, _) = await _pair();

        final frame = await host.seal(utf8.encode('mine'));

        await expectLater(
          host.unseal(frame),
          throwsA(isA<SealedFrameException>()),
        );
      },
    );

    test('a frame from another pairing', () async {
      final (host, _) = await _pair();
      final stranger = await SealedChannel.forDevice(
        deviceKey: await _deviceKey(deviceId: DeviceId.parse('99' * 16)),
        role: ChannelRole.companion,
      );

      await expectLater(
        stranger.unseal(await host.seal(utf8.encode('hello'))),
        throwsA(isA<SealedFrameException>()),
      );
    });

    test('a frame from an earlier rendezvous generation', () async {
      final (oldHost, _) = await _pair();
      final (_, newCompanion) = await _pair(generation: 1);

      await expectLater(
        newCompanion.unseal(await oldHost.seal(utf8.encode('stale'))),
        throwsA(isA<SealedFrameException>()),
      );
    });

    test('a frame with a flipped bit', () async {
      final (host, companion) = await _pair();
      final frame = await host.seal(utf8.encode('hello'));
      frame[frame.length - 1] ^= 0x01;

      await expectLater(
        companion.unseal(frame),
        throwsA(isA<SealedFrameException>()),
      );
    });

    test('a frame with a tampered nonce', () async {
      final (host, companion) = await _pair();
      final frame = await host.seal(utf8.encode('hello'));
      frame[0] ^= 0xff;

      await expectLater(
        companion.unseal(frame),
        throwsA(isA<SealedFrameException>()),
      );
    });

    test('a frame too short to hold its own overhead', () async {
      final (_, companion) = await _pair();

      await expectLater(
        companion.unseal(Uint8List(kSealedFrameOverhead - 1)),
        throwsA(isA<SealedFrameException>()),
      );
    });

    test('a truncated frame', () async {
      final (host, companion) = await _pair();
      final frame = await host.seal(utf8.encode('a longer message here'));

      await expectLater(
        companion.unseal(frame.sublist(0, frame.length - 4)),
        throwsA(isA<SealedFrameException>()),
      );
    });

    test('its complaint never quotes the frame', () async {
      final (host, companion) = await _pair();
      final frame = await host.seal(utf8.encode('SENSITIVE'));
      frame[frame.length - 1] ^= 0x01;

      try {
        await companion.unseal(frame);
        fail('expected a refusal');
      } on SealedChannelException catch (error) {
        expect(error.toString(), isNot(contains('SENSITIVE')));
        expect(error.toString(), 'SealedFrameException: authentication failed');
      }
    });
  });

  group('replay and reorder', () {
    test('the same frame twice is rejected the second time', () async {
      final (host, companion) = await _pair();
      final frame = await host.seal(utf8.encode('approve'));

      await companion.unseal(frame);

      await expectLater(
        companion.unseal(frame),
        throwsA(isA<ReplayedFrameException>()),
      );
    });

    test('a frame replayed after later ones is still rejected', () async {
      final (host, companion) = await _pair();
      final first = await host.seal([1]);
      final second = await host.seal([2]);

      await companion.unseal(first);
      await companion.unseal(second);

      await expectLater(
        companion.unseal(first),
        throwsA(isA<ReplayedFrameException>()),
      );
    });

    test(
      'frames that arrive out of order inside the window are kept',
      () async {
        final (host, companion) = await _pair();
        final frames = [
          for (var i = 0; i < 5; i++) await host.seal([i]),
        ];

        final delivered = <int>[];
        for (final index in [4, 0, 3, 1, 2]) {
          delivered.add((await companion.unseal(frames[index])).sequence);
        }

        expect(delivered, [4, 0, 3, 1, 2]);
        expect(companion.highestReceivedSequence, 4);
      },
    );

    test('a frame older than the window is rejected', () async {
      final (host, companion) = await _pair();
      final first = await host.seal([0]);
      for (var i = 1; i <= kDefaultReplayWindow; i++) {
        await companion.unseal(await host.seal([i]));
      }

      await expectLater(
        companion.unseal(first),
        throwsA(isA<ReplayedFrameException>()),
      );
    });

    test('the window size is configurable', () async {
      final key = await _deviceKey();
      final host = await SealedChannel.forDevice(
        deviceKey: key,
        role: ChannelRole.host,
      );
      final companion = await SealedChannel.forDevice(
        deviceKey: key,
        role: ChannelRole.companion,
        replayWindow: 2,
      );
      final first = await host.seal([0]);
      await companion.unseal(await host.seal([1]));
      await companion.unseal(await host.seal([2]));

      await expectLater(
        companion.unseal(first),
        throwsA(isA<ReplayedFrameException>()),
      );
    });

    test('a gap the size of a lost burst is accepted', () async {
      final (host, companion) = await _pair();
      final first = await host.seal([0]);
      for (var i = 0; i < 100; i++) {
        await host.seal([i]);
      }
      final afterGap = await host.seal([255]);

      await companion.unseal(first);
      final opened = await companion.unseal(afterGap);

      expect(opened.sequence, 101);
      expect(opened.plaintext, [255]);
    });

    test('a wild jump forward is refused', () async {
      final key = await _deviceKey();
      final host = await SealedChannel.forDevice(
        deviceKey: key,
        role: ChannelRole.host,
      );
      final companion = await SealedChannel.forDevice(
        deviceKey: key,
        role: ChannelRole.companion,
        maxForwardGap: 4,
      );

      await companion.unseal(await host.seal([0]));
      for (var i = 0; i < 10; i++) {
        await host.seal([i]);
      }

      await expectLater(
        companion.unseal(await host.seal([1])),
        throwsA(isA<SequenceGapException>()),
      );
    });

    test('the first frame is accepted whatever its sequence', () async {
      final (host, companion) = await _pair();
      for (var i = 0; i < 5000; i++) {
        await host.seal([0]);
      }

      final opened = await companion.unseal(await host.seal([1]));

      expect(opened.sequence, 5000);
    });

    test('refuses a nonsensical window', () async {
      final key = await _deviceKey();

      await expectLater(
        SealedChannel.forDevice(
          deviceKey: key,
          role: ChannelRole.host,
          replayWindow: 0,
        ),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        SealedChannel.forDevice(
          deviceKey: key,
          role: ChannelRole.host,
          maxForwardGap: 0,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('roles', () {
    test('seal and open opposite directions', () {
      expect(ChannelRole.host.sends, ChannelDirection.hostToDevice);
      expect(ChannelRole.host.receives, ChannelDirection.deviceToHost);
      expect(ChannelRole.companion.sends, ChannelDirection.deviceToHost);
      expect(ChannelRole.companion.receives, ChannelDirection.hostToDevice);
    });
  });

  group('committed vectors', () {
    late Map<String, Object?> vectors;
    late SecretKeyData deviceKey;

    setUpAll(() async {
      vectors =
          jsonDecode(
                File(
                  'test/features/remote/remote_test_vectors.json',
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      deviceKey = await deriveDeviceKey(
        pairingSecret: _hex(vectors['pairingSecret']! as String),
        hostId: DeviceId.parse(vectors['hostId']! as String),
        deviceId: DeviceId.parse(vectors['deviceId']! as String),
      );
    });

    test('open to their recorded plaintext', () async {
      for (final vector
          in (vectors['frames']! as List).cast<Map<String, Object?>>()) {
        final sealedBy = ChannelRole.values.byName(vector['role']! as String);
        final receiver = await SealedChannel.forDevice(
          deviceKey: deviceKey,
          role: sealedBy == ChannelRole.host
              ? ChannelRole.companion
              : ChannelRole.host,
          generation: vector['generation']! as int,
        );

        final opened = await receiver.unseal(_hex(vector['frame']! as String));

        expect(
          _toHex(opened.plaintext),
          vector['plaintext'],
          reason: '${vector['role']} frame ${vector['sequence']}',
        );
        expect(opened.sequence, vector['sequence']);
      }
    });

    test('are reproduced byte for byte from the pinned nonces', () async {
      for (final role in ChannelRole.values) {
        final mine = (vectors['frames']! as List)
            .cast<Map<String, Object?>>()
            .where((v) => v['role'] == role.name)
            .toList();
        var index = 0;
        final channel = await SealedChannel.forDevice(
          deviceKey: deviceKey,
          role: role,
          nonceSource: () => _hex(mine[index++]['nonce']! as String),
        );

        for (final vector in mine) {
          expect(
            _toHex(await channel.seal(_hex(vector['plaintext']! as String))),
            vector['frame'],
            reason: '${role.name} frame ${vector['sequence']}',
          );
        }
      }
    });

    test('describe the frame format the companion must implement', () {
      expect(
        vectors['aead'],
        'XChaCha20-Poly1305, frame = nonce(24) || ciphertext || mac(16), '
        'sealed plaintext = uint64be(sequence) || payload, '
        'aad = the direction label',
      );
    });
  });
}

String _toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _hex(String value) => Uint8List.fromList([
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
]);
