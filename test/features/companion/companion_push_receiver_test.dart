/// The decrypt-and-render side of push: real sealed bytes in, the existing
/// notification wording out — and nothing at all for bytes that will not open.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala/src/app/companion/companion_push_entry.dart';
import 'package:karmashala/src/features/companion/notifications/attention_notification.dart';
import 'package:karmashala/src/features/companion/push/companion_push_receiver.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/push.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

final Uint8List _key = Uint8List.fromList(List.generate(32, (i) => i * 3));

void main() {
  late InMemoryCompanionStore store;
  late List<AttentionNotification> shown;
  late List<String> log;
  late CompanionPushReceiver receiver;

  setUp(() async {
    store = InMemoryCompanionStore();
    await CompanionPairing(
      hostId: DeviceId.parse('11111111222222223333333344444444'),
      deviceId: DeviceId.parse('aaaaaaaabbbbbbbbccccccccdddddddd'),
      deviceKey: _key,
      capabilities: CapabilitySet.all,
      relay: Uri.parse('wss://relay.example.com'),
      generation: 3,
      hostName: 'Desktop',
    ).save(store);
    shown = [];
    log = [];
    receiver = CompanionPushReceiver(
      store: store,
      show: (notification) async => shown.add(notification),
      now: () => DateTime.utc(2026, 8, 31),
      onLog: log.add,
    );
  });

  Future<String> sealed({
    String sessionId = 's1',
    String title = 'Fix the tests',
    String kind = 'needs_approval',
    Uint8List? key,
  }) async => base64Url.encode(
    await sealPushPayload(
      deviceKey: SecretKeyData(key ?? _key),
      payload: attentionPushPayload(
        sessionId: sessionId,
        title: title,
        kind: kind,
        at: DateTime.utc(2026, 8, 31, 10),
      ),
    ),
  );

  test('unseals and renders through the existing wording', () async {
    await receiver.handleOpaquePayload(await sealed());

    final notification = shown.single;
    expect(notification.title, 'Fix the tests');
    expect(notification.body, 'Waiting for your approval or input.');
    expect(notification.sessionId, 's1');
    expect(notification.id, stableNotificationId('s1'));
  });

  test('maps every wire kind to its inbox wording', () async {
    await receiver.handleOpaquePayload(await sealed(kind: 'finished'));
    await receiver.handleOpaquePayload(await sealed(kind: 'failed'));
    await receiver.handleOpaquePayload(await sealed(kind: 'surprising'));

    expect(shown[0].body, 'Finished a turn — open it when you are ready.');
    expect(shown[1].body, 'The turn ended in error.');
    // An unknown claim on the user reads as "needs you" — the gateway's rule.
    expect(shown[2].body, 'Waiting for your approval or input.');
  });

  test('handles the FCM data-map shape', () async {
    await receiver.handleData(<Object?, Object?>{'payload': await sealed()});
    await receiver.handleData(<Object?, Object?>{'something': 'else'});

    expect(shown, hasLength(1));
  });

  test('the entry seam routes a message to the receiver', () async {
    await handleCompanionPushMessage(<Object?, Object?>{
      'payload': await sealed(),
    }, receiver: receiver);

    expect(shown, hasLength(1));
  });

  test('bytes sealed for another pairing show nothing', () async {
    final strangers = Uint8List.fromList(List.generate(32, (i) => 200 - i));

    await receiver.handleOpaquePayload(await sealed(key: strangers));

    expect(shown, isEmpty);
    expect(log.single, startsWith('push payload refused'));
    expect(log.single, isNot(contains('Fix the tests')));
  });

  test('tampered or garbage payloads show nothing and never throw', () async {
    final bytes = base64Url.decode(await sealed());
    bytes[bytes.length - 1] ^= 0x01;

    await receiver.handleOpaquePayload(base64Url.encode(bytes));
    await receiver.handleOpaquePayload('not even base64!!');
    await receiver.handleOpaquePayload('');

    expect(shown, isEmpty);
  });

  test('an unpaired phone drops the push', () async {
    final payload = await sealed();
    await store.delete(CompanionPairing.storeKey);

    await receiver.handleOpaquePayload(payload);

    expect(shown, isEmpty);
    expect(log, contains('push for an unpaired phone dropped'));
  });

  test('a payload naming no session shows nothing', () async {
    final payload = base64Url.encode(
      await sealPushPayload(
        deviceKey: SecretKeyData(_key),
        payload: {'v': 1, 'kind': 'failed'},
      ),
    );

    await receiver.handleOpaquePayload(payload);

    expect(shown, isEmpty);
  });

  test('a missing title falls back to the session id', () async {
    final payload = base64Url.encode(
      await sealPushPayload(
        deviceKey: SecretKeyData(_key),
        payload: {'v': 1, 'sessionId': 's9', 'kind': 'failed'},
      ),
    );

    await receiver.handleOpaquePayload(payload);

    expect(shown.single.title, 's9');
    expect(shown.single.sessionId, 's9');
  });
}
