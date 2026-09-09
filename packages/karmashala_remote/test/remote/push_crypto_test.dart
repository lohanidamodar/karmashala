import 'dart:typed_data';

import 'package:karmashala_remote/push.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

void main() {
  final keyA = SecretKeyData(Uint8List.fromList(List.generate(32, (i) => i)));
  final keyB = SecretKeyData(
    Uint8List.fromList(List.generate(32, (i) => (i + 100) & 0xff)),
  );

  group('the push tag', () {
    test('is 32 lowercase hex, stable per key, distinct per key', () async {
      final tag = await derivePushTag(keyA);

      expect(tag, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(await derivePushTag(keyA), tag);
      expect(await derivePushTag(keyB), isNot(tag));
    });

    test('cannot be linked to any rendezvous id', () async {
      final tag = await derivePushTag(keyA);

      for (var generation = 0; generation < 8; generation++) {
        final rendezvous = await rendezvousFor(keyA, generation);
        expect(tag, isNot(rendezvous.value));
      }
    });
  });

  group('sealing and opening', () {
    final payload = attentionPushPayload(
      sessionId: 's1',
      title: 'Fix the tests',
      kind: 'needs_approval',
      at: DateTime.utc(2026, 8, 31, 10),
    );

    test('round-trips the attention payload', () async {
      final sealed = await sealPushPayload(deviceKey: keyA, payload: payload);

      final opened = await openPushPayload(deviceKey: keyA, sealed: sealed);

      expect(opened, {
        'v': 1,
        'sessionId': 's1',
        'title': 'Fix the tests',
        'kind': 'needs_approval',
        'at': '2026-08-31T10:00:00.000Z',
      });
    });

    test('two seals of the same payload differ (fresh nonce)', () async {
      final one = await sealPushPayload(deviceKey: keyA, payload: payload);
      final two = await sealPushPayload(deviceKey: keyA, payload: payload);

      expect(one, isNot(two));
    });

    test('a tampered byte is refused, naming no contents', () async {
      final sealed = await sealPushPayload(deviceKey: keyA, payload: payload);
      sealed[sealed.length - 1] ^= 0x01;

      await expectLater(
        openPushPayload(deviceKey: keyA, sealed: sealed),
        throwsA(
          isA<PushPayloadException>().having(
            (e) => e.toString(),
            'message',
            isNot(contains('Fix the tests')),
          ),
        ),
      );
    });

    test('another pairing\'s key is refused', () async {
      final sealed = await sealPushPayload(deviceKey: keyA, payload: payload);

      await expectLater(
        openPushPayload(deviceKey: keyB, sealed: sealed),
        throwsA(isA<PushPayloadException>()),
      );
    });

    test('truncated or garbage bytes are refused', () async {
      await expectLater(
        openPushPayload(deviceKey: keyA, sealed: Uint8List(12)),
        throwsA(isA<PushPayloadException>()),
      );
      await expectLater(
        openPushPayload(
          deviceKey: keyA,
          sealed: Uint8List.fromList(List.generate(80, (i) => i)),
        ),
        throwsA(isA<PushPayloadException>()),
      );
    });
  });
}
