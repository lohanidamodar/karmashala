/// A slow or absent reader is a property of the stream, not of a buffer.
///
/// The phone acks the host frames it rendered; above a watermark of unacked
/// bytes the host holds its news, below a lower one it resumes with current
/// state, and a stream with no ack progress fails closed with a named code.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/remote/application/remote_host_service.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_store/devices.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bindings.dart';
import 'transport_harness.dart';

final _hostId = DeviceId.parse('11111111222222223333333344444444');
final _deviceId = DeviceId.parse('aaaaaaaabbbbbbbbccccccccdddddddd');
final _secret = Uint8List.fromList(List<int>.generate(32, (i) => 0x51 + i));

void main() {
  late AppDatabase db;
  late PairedDeviceDao dao;
  late FakeRemoteBindings fake;
  late RelayServer relay;
  late Uri relayUri;
  late RemoteHostService service;
  late List<StreamFlow> flows;
  final cleanups = <Future<void> Function()>[];

  setUp(() async {
    db = AppDatabase.memory();
    dao = PairedDeviceDao(db);
    fake = FakeRemoteBindings()..addSession('s1');
    flows = [];
    relay = await RelayServer.bind(
      address: '127.0.0.1',
      port: 0,
      options: const RelayOptions(loneTimeout: Duration.zero),
    );
    relayUri = Uri.parse('http://127.0.0.1:${relay.port}');
  });

  tearDown(() async {
    for (final cleanup in cleanups.reversed.toList()) {
      await cleanup();
    }
    cleanups.clear();
    await service.stop();
    await relay.close();
    db.close();
  });

  Future<SecretKeyData> deviceKey() => deriveDeviceKey(
    pairingSecret: _secret,
    hostId: _hostId,
    deviceId: _deviceId,
  );

  Future<void> start({
    StreamFlow Function()? flow,
    Duration watchLease = kWatchLease,
  }) async {
    dao.insert(
      PairedDevice(
        id: _deviceId.value,
        name: 'OPPO',
        deviceKey: Uint8List.fromList((await deviceKey()).bytes),
        capabilities: CapabilitySet.all,
        generation: kFirstSessionGeneration,
        createdAt: DateTime.utc(2026, 9, 23),
      ),
    );
    service = RemoteHostService(
      devices: dao,
      hostId: _hostId,
      bindings: fake.bindings,
      relay: relayUri,
      lanPort: 0,
      advertise: false,
      transcriptPollInterval: Duration.zero,
      watchLease: watchLease,
      newStreamFlow: () {
        final made = (flow ?? StreamFlow.new)();
        flows.add(made);
        return made;
      },
      relayFactory: (relay, rendezvous) => RelayTransport(
        endpoint: RelayTransport.endpointFor(relay, rendezvous),
        backoff: fastBackoff(),
        heartbeat: const Duration(milliseconds: 500),
      )..start(),
    );
    await service.start();
  }

  Future<void> until(String what, bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('never $what');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> desktopChanged(int nth) async {
    // Padded so a handful of changes crosses a small watermark.
    fake.addSession('s1', title: 'change $nth ${'.' * 600}');
    await service.notifySessionsChanged();
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }

  test('a phone that acks is told the host reads acks, and keeps the '
      'window empty', () async {
    await start();
    final client = CompanionClient(
      pairing: CompanionPairing(
        hostId: _hostId,
        deviceId: _deviceId,
        deviceKey: Uint8List.fromList((await deviceKey()).bytes),
        capabilities: CapabilitySet.all,
        relay: relayUri,
        generation: kFirstSessionGeneration,
        hostName: 'TestHost',
      ),
      store: InMemoryCompanionStore(),
      relayFactory: (relay, rendezvous) => RelayTransport(
        endpoint: RelayTransport.endpointFor(relay, rendezvous),
        backoff: fastBackoff(),
        heartbeat: const Duration(milliseconds: 500),
      )..start(),
    );
    cleanups.add(client.close);
    final status = await client.connect(
      helloTimeout: const Duration(seconds: 5),
    );
    expect(status.streamAcks, isTrue);
    await client.listSessions();
    await client.subscribeSession('s1');
    for (var i = 0; i < 20; i++) {
      await desktopChanged(i);
    }
    await until('heard the phone ack', () => flows.last.enabled);
    await until('saw every frame acked', () => flows.last.unackedBytes == 0);
  });

  test('a phone that stops acking is held, then given current state — not '
      'a replay — when it acks again', () async {
    await start(
      flow: () => StreamFlow(highWatermark: 3000, lowWatermark: 1000),
    );
    final phone = await _RawPhone.connect(relayUri, await deviceKey());
    cleanups.add(phone.close);
    await phone.request(FrameType.sessionsList);
    await phone.request(FrameType.sessionSubscribe, {'sessionId': 's1'});
    phone.ack();

    for (var i = 0; i < 30; i++) {
      await desktopChanged(i);
    }
    final heldAt = phone.changes.length;
    expect(heldAt, lessThan(10), reason: 'news past the watermark went out');
    for (var i = 30; i < 40; i++) {
      await desktopChanged(i);
    }
    expect(phone.changes.length, heldAt, reason: 'a held stream kept pushing');

    phone.ack();
    await until('heard current state', () => phone.changes.length > heldAt);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(phone.changes.length, heldAt + 1, reason: 'held news was replayed');
    expect(phone.changes.last, startsWith('change 39 '));
  });

  test(
    'a stream with no ack progress fails closed with a named code',
    () async {
      await start(
        flow: () => StreamFlow(
          highWatermark: 3000,
          lowWatermark: 1000,
          stallTimeout: const Duration(milliseconds: 200),
        ),
      );
      final phone = await _RawPhone.connect(relayUri, await deviceKey());
      cleanups.add(phone.close);
      await phone.request(FrameType.sessionsList);
      await phone.request(FrameType.sessionSubscribe, {'sessionId': 's1'});
      phone.ack();

      for (var i = 0; i < 10; i++) {
        await desktopChanged(i);
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await desktopChanged(10);
      await until('was told the stream stalled', () {
        return phone.errors.contains(ErrorCode.streamStalled.wire);
      });
      expect(service.hasLiveLink(_deviceId.value), isTrue);
    },
  );

  group('connected is not watching', () {
    Future<_RawPhone> subscribed() async {
      final phone = await _RawPhone.connect(relayUri, await deviceKey());
      cleanups.add(phone.close);
      await phone.request(FrameType.sessionsList);
      await phone.request(FrameType.sessionSubscribe, {'sessionId': 's1'});
      return phone;
    }

    test('a pocketed phone is not streamed changes, and is shown where '
        'things stand when it looks again', () async {
      await start();
      final phone = await subscribed();
      phone.ack(watching: false);
      await until('heard it stop looking', () {
        return !service.isWatching(_deviceId.value);
      });
      expect(service.hasLiveLink(_deviceId.value), isTrue);
      final before = phone.changes.length;

      for (var i = 0; i < 5; i++) {
        await desktopChanged(i);
      }
      expect(phone.changes.length, before, reason: 'a pocket was streamed');

      phone.ack(watching: true);
      await until('heard current state', () => phone.changes.length > before);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        phone.changes.length,
        before + 1,
        reason: 'the pocket was replayed',
      );
      expect(phone.changes.last, startsWith('change 4 '));
    });

    test('watching lapses when it is not renewed', () async {
      await start(watchLease: const Duration(milliseconds: 300));
      final phone = await subscribed();
      phone.ack(watching: true);
      await until('heard it look', () => service.isWatching(_deviceId.value));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(service.isWatching(_deviceId.value), isFalse);
      expect(service.hasLiveLink(_deviceId.value), isTrue);
    });

    test(
      'a phone that never says is watching while connected, as before',
      () async {
        await start();
        final phone = await subscribed();
        phone.ack();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(service.isWatching(_deviceId.value), isTrue);
        final before = phone.changes.length;
        await desktopChanged(1);
        await until('heard the change', () => phone.changes.length > before);
      },
    );

    test(
      'the client says what the owner is doing the moment it changes',
      () async {
        await start();
        bool? looking = true;
        final client = CompanionClient(
          pairing: CompanionPairing(
            hostId: _hostId,
            deviceId: _deviceId,
            deviceKey: Uint8List.fromList((await deviceKey()).bytes),
            capabilities: CapabilitySet.all,
            relay: relayUri,
            generation: kFirstSessionGeneration,
            hostName: 'TestHost',
          ),
          store: InMemoryCompanionStore(),
          watching: () => looking,
          relayFactory: (relay, rendezvous) => RelayTransport(
            endpoint: RelayTransport.endpointFor(relay, rendezvous),
            backoff: fastBackoff(),
            heartbeat: const Duration(milliseconds: 500),
          )..start(),
        );
        cleanups.add(client.close);
        await client.connect(helloTimeout: const Duration(seconds: 5));
        await until('heard it look', () => service.isWatching(_deviceId.value));

        looking = false;
        client.presenceChanged();
        await until(
          'heard it stop',
          () => !service.isWatching(_deviceId.value),
        );

        looking = true;
        client.presenceChanged();
        await until('heard it look again', () {
          return service.isWatching(_deviceId.value);
        });
      },
    );
  });
}

/// A phone reduced to the wire, so a test can decide when it acks.
class _RawPhone {
  _RawPhone._(this._transport, this._channel);

  static Future<_RawPhone> connect(Uri relay, SecretKeyData key) async {
    final rendezvous = await rendezvousFor(key, kFirstSessionGeneration);
    final transport = RelayTransport(
      endpoint: RelayTransport.endpointFor(relay, rendezvous),
      backoff: fastBackoff(),
      heartbeat: const Duration(milliseconds: 500),
    )..start();
    final channel = await SealedChannel.forDevice(
      deviceKey: key,
      role: ChannelRole.companion,
      generation: kFirstSessionGeneration,
    );
    final phone = _RawPhone._(transport, channel);
    phone._subscription = transport.frames.listen(phone._onFrame);
    transport.send(LinkHello(rendezvous).encode());
    await phone._greeted.future.timeout(const Duration(seconds: 5));
    return phone;
  }

  final RemoteTransport _transport;
  final SealedChannel _channel;
  late final StreamSubscription<Uint8List> _subscription;
  final Completer<void> _greeted = Completer<void>();
  final Map<String, Completer<void>> _pending = {};
  int _highest = -1;
  int _nextId = 0;

  /// The title of every `session.changed` heard, in order.
  final List<String> changes = [];
  final List<String> errors = [];

  Future<void> _onFrame(Uint8List frame) async {
    final opened = await _channel.unseal(frame);
    final envelope = Envelope.fromBytes(opened.plaintext);
    if (opened.sequence > _highest) _highest = opened.sequence;
    switch (envelope.knownType) {
      case FrameType.hostStatus:
        if (!_greeted.isCompleted) _greeted.complete();
      case FrameType.result:
        _pending.remove(envelope.id)?.complete();
      case FrameType.sessionChanged:
        changes.add(envelope.payload['title']! as String);
      case FrameType.error:
        errors.add(envelope.payload['code']! as String);
      default:
    }
  }

  Future<void> _send(FrameType type, String? id, Map<String, Object?> p) async {
    final envelope = Envelope.of(
      type,
      seq: _channel.nextSendSequence,
      id: id,
      payload: p,
    );
    _transport.send(await _channel.seal(envelope.toBytes()));
  }

  Future<void> request(
    FrameType type, [
    Map<String, Object?> payload = const {},
  ]) async {
    final id = 'r${_nextId++}';
    final done = _pending[id] = Completer<void>();
    await _send(type, id, payload);
    await done.future.timeout(const Duration(seconds: 5));
  }

  void ack({bool? watching}) => unawaited(
    _send(FrameType.streamAck, null, {'seq': _highest, 'watching': ?watching}),
  );

  Future<void> close() async {
    await _subscription.cancel();
    await _transport.close();
  }
}
