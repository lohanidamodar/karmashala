/// Attention-inbox news → the push fan-out: new items push, listed items
/// do not repeat, imported and delivery kinds stay on the desktop.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/features/notifications/domain/agent_session_key.dart';
import 'package:chitragupta/src/features/notifications/domain/inbox_item.dart';
import 'package:chitragupta/src/features/notifications/domain/watched_session.dart';
import 'package:chitragupta/src/features/remote/application/remote_access_controller.dart';
import 'package:chitragupta/src/features/remote/application/remote_host_service.dart';
import 'package:chitragupta/src/features/remote/data/paired_device_dao.dart';
import 'package:chitragupta/src/features/remote/domain/paired_device.dart';
import 'package:chitragupta/src/features/remote/protocol.dart';
import 'package:chitragupta/src/features/remote/push/push_crypto.dart';
import 'package:chitragupta/src/features/remote/transport/relay_transport.dart';
import 'package:chitragupta/src/features/settings/application/settings_controller.dart';
import 'package:chitragupta_relay/chitragupta_relay.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bindings.dart';
import 'transport_harness.dart';

final Uint8List _key = Uint8List.fromList(List.generate(32, (i) => i));

InboxItem _item(
  String openId, {
  InboxItemKind kind = InboxItemKind.finished,
  bool imported = false,
  String label = 'Fix the tests',
}) => InboxItem(
  session: WatchedSession(
    key: AgentSessionKey('claude-code', 'ext-$openId'),
    label: label,
    openId: openId,
    imported: imported,
  ),
  kind: kind,
  at: DateTime.utc(2026, 8, 31, 12),
);

AttentionInbox _inbox(List<InboxItem> items) => AttentionInbox(items: items);

Future<void> _eventually(
  bool Function() condition, {
  String reason = 'condition never held',
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail(reason);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late AppDatabase db;
  late PairedDeviceDao dao;
  late ProviderContainer container;
  late RelayServer relay;
  late RemoteAccessController controller;
  late List<({Uri url, String raw})> posts;

  setUp(() async {
    db = AppDatabase.memory();
    dao = PairedDeviceDao(db);
    posts = [];
    relay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    final fake = FakeRemoteBindings()..addSession('s1');
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        remoteAccessControllerProvider.overrideWith(
          (ref) => RemoteAccessController(
            ref,
            serviceFactory: (relayUri) => RemoteHostService(
              devices: dao,
              hostId: DeviceId.parse('11111111222222223333333344444444'),
              bindings: fake.bindings,
              relay: relayUri,
              lanPort: 0,
              advertise: false,
              transcriptPollInterval: Duration.zero,
              relayFactory: (relay, rendezvous) => RelayTransport(
                endpoint: RelayTransport.endpointFor(relay, rendezvous),
                backoff: fastBackoff(),
                heartbeat: const Duration(milliseconds: 500),
              )..start(),
              pushPost: (url, jsonBody) async {
                posts.add((url: url, raw: jsonBody));
                return url.path.endsWith('/register')
                    ? (status: 204, body: '')
                    : (status: 202, body: 'accepted\n');
              },
            ),
          ),
        ),
      ],
    );
    controller = container.read(remoteAccessControllerProvider);

    dao.insert(
      PairedDevice(
        id: 'a' * 32,
        name: 'OPPO',
        deviceKey: _key,
        capabilities: CapabilitySet.all,
        generation: 1,
        createdAt: DateTime.utc(2026, 8, 31),
        pushToken: 'fcm-oppo-1',
        pushPlatform: 'android',
      ),
    );
    final settings = container.read(settingsControllerProvider.notifier);
    settings.setRemoteAccessEnabled(true);
    settings.setRemoteRelayUrl('http://127.0.0.1:${relay.port}');
    await controller.sync();
  });

  tearDown(() async {
    await controller.shutdown();
    container.dispose();
    await relay.close();
    db.close();
  });

  test('a new finished item becomes one sealed push', () async {
    controller.onInboxChanged(AttentionInbox.empty, _inbox([_item('s1')]));

    await _eventually(() => posts.length == 2);
    expect(
      [for (final p in posts) p.url.path],
      ['/v1/push/register', '/v1/push'],
    );
    final body = jsonDecode(posts[1].raw) as Map<String, Object?>;
    final opened = await openPushPayload(
      deviceKey: SecretKeyData(_key),
      sealed: base64Url.decode(body['payload']! as String),
    );
    expect(opened['sessionId'], 's1');
    expect(opened['title'], 'Fix the tests');
    expect(opened['kind'], 'finished');
  });

  test('only the newly arrived item is pushed', () async {
    final already = _item('s1');
    controller.onInboxChanged(
      _inbox([already]),
      _inbox([_item('s2', kind: InboxItemKind.failed), already]),
    );

    await _eventually(() => posts.length == 2);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(posts.length, 2, reason: 'the listed item must not re-push');
    final body = jsonDecode(posts[1].raw) as Map<String, Object?>;
    final opened = await openPushPayload(
      deviceKey: SecretKeyData(_key),
      sealed: base64Url.decode(body['payload']! as String),
    );
    expect(opened['sessionId'], 's2');
    expect(opened['kind'], 'failed');
  });

  test('needs-approval news carries the wire word needs_approval', () async {
    controller.onInboxChanged(
      AttentionInbox.empty,
      _inbox([_item('s1', kind: InboxItemKind.needsApproval)]),
    );

    await _eventually(() => posts.length == 2);
    final body = jsonDecode(posts[1].raw) as Map<String, Object?>;
    final opened = await openPushPayload(
      deviceKey: SecretKeyData(_key),
      sealed: base64Url.decode(body['payload']! as String),
    );
    expect(opened['kind'], 'needs_approval');
  });

  test('imported sessions and delivery kinds stay on the desktop', () async {
    controller.onInboxChanged(
      AttentionInbox.empty,
      _inbox([
        _item('s1', imported: true),
        _item('s2', kind: InboxItemKind.checksFailed),
        _item('s3', kind: InboxItemKind.readyToMerge),
        _item('s4', kind: InboxItemKind.changesRequested),
      ]),
    );

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(posts, isEmpty);
  });

  test('with remote access off, inbox news drops quietly', () async {
    container
        .read(settingsControllerProvider.notifier)
        .setRemoteAccessEnabled(false);
    await controller.sync();

    controller.onInboxChanged(AttentionInbox.empty, _inbox([_item('s1')]));

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(posts, isEmpty);
  });
}
