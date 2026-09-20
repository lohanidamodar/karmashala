@Tags(['live'])
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';
import 'package:test/test.dart';

/// A real socket on loopback, because what is under test is the accept path: a
/// hello in the clear, a rendezvous nobody can read backwards, and everything
/// after it sealed. A fake transport would skip exactly that.
void main() {
  late AppDatabase database;
  late SessionRegistry registry;
  late CompanionListener listener;
  final logs = <String>[];

  /// The phone's key, and the row a completed pairing would have written.
  final deviceKey = Uint8List.fromList(List.generate(32, (i) => i + 1));

  setUp(() async {
    database = AppDatabase.memory();
    registry = SessionRegistry(launcher: FakePtyLauncher());
    logs.clear();
    PairedDeviceDao(database).insert(
      PairedDevice(
        id: 'pixel-7',
        name: 'Pixel 7',
        deviceKey: deviceKey,
        capabilities: CapabilitySet.all,
        generation: 0,
        createdAt: DateTime.utc(2026, 9, 16),
      ),
    );
    listener = CompanionListener(
      registry: registry,
      hostName: 'do-box',
      devices: PairedDeviceDao(database).getActive,
      onLog: logs.add,
    );
    // Port 0: the OS picks a free one, so the suite never fights a real host.
    await listener.start(address: '127.0.0.1', port: 0);
  });

  tearDown(() async {
    await listener.stop();
    database.close();
  });

  /// Dials the listener the way a paired phone does, and opens what comes back.
  /// Drained with `await for` so frames unseal in order — the channel's replay
  /// window is a sequence, not a set.
  Future<({LanTransport link, SealedChannel channel, List<Envelope> answers})>
  dialAsPhone() async {
    final link = LanTransport(host: '127.0.0.1', port: listener.port)..start();
    final key = SecretKeyData(deviceKey);
    final channel = await SealedChannel.forDevice(
      deviceKey: key,
      role: ChannelRole.companion,
      generation: 0,
    );
    final answers = <Envelope>[];
    unawaited(() async {
      await for (final sealed in link.frames) {
        final opened = await channel.unseal(sealed);
        answers.add(Envelope.fromBytes(opened.plaintext));
      }
    }());
    link.send(LinkHello(await rendezvousFor(key, 0)).encode());
    return (link: link, channel: channel, answers: answers);
  }

  /// Waits for an answer carrying [id].
  Future<Envelope> answerTo(List<Envelope> answers, String id) async {
    await Future.doWhile(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return !answers.any((e) => e.id == id);
    }).timeout(const Duration(seconds: 10));
    return answers.firstWhere((e) => e.id == id);
  }

  test('a paired phone reaches the sessions this machine owns', () async {
    registry.open(
      'karmashala_live',
      const PtySpawnRequest(
        argv: ['claude'],
        workingDirectory: '/srv/app',
        environment: {},
        columns: 80,
        rows: 24,
      ),
    );
    final phone = await dialAsPhone();
    addTearDown(phone.link.close);

    phone.link.send(
      await phone.channel.seal(
        Envelope.of(FrameType.sessionsList, seq: 1, id: 'r1').toBytes(),
      ),
    );

    final answer = await answerTo(phone.answers, 'r1');

    expect(answer.type, FrameType.result.wire);
    final sessions = (answer.payload['sessions']! as List)
        .cast<Map<String, Object?>>();
    expect(sessions.single['sessionId'], 'karmashala_live');
  });

  test('a dialer with no rendezvous is closed, not answered', () async {
    final stranger = LanTransport(host: '127.0.0.1', port: listener.port)
      ..start();
    addTearDown(stranger.close);

    // A rendezvous derived from a key this host has never seen.
    final theirs = SecretKeyData(Uint8List.fromList(List.filled(32, 9)));
    stranger.send(LinkHello(await rendezvousFor(theirs, 0)).encode());

    await Future.doWhile(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return !logs.any((l) => l.contains('nobody here answers'));
    }).timeout(const Duration(seconds: 10));

    expect(logs, contains(contains('nobody here answers')));
  });

  test('a dialer that does not say hello is closed', () async {
    final stranger = LanTransport(host: '127.0.0.1', port: listener.port)
      ..start();
    addTearDown(stranger.close);

    stranger.send(Uint8List.fromList('hello?'.codeUnits));

    await Future.doWhile(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return !logs.any((l) => l.contains('other than a hello'));
    }).timeout(const Duration(seconds: 10));

    expect(logs, contains(contains('other than a hello')));
  });

  test('a link that says nothing is not held for ever', () async {
    // `maxLinks` caps how many an outsider holds at once; this caps how long.
    // On a public address, opening a socket and saying nothing is the cheapest
    // thing anybody can do, so it has to cost them the connection.
    final silent = CompanionListener(
      registry: registry,
      hostName: 'do-box',
      devices: PairedDeviceDao(database).getActive,
      onLog: logs.add,
    );
    await silent.start(address: '127.0.0.1', port: 0);
    addTearDown(silent.stop);

    final lurker = LanTransport(host: '127.0.0.1', port: silent.port)..start();
    addTearDown(lurker.close);

    await Future.doWhile(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return !logs.any((l) => l.contains('said nothing'));
    }).timeout(CompanionListener.helloDeadline + const Duration(seconds: 10));

    expect(logs, contains(contains('said nothing')));
  }, timeout: const Timeout(Duration(seconds: 40)));

  test(
    'a frame sealed with the wrong key is refused, and the link survives',
    () async {
      final phone = await dialAsPhone();
      addTearDown(phone.link.close);

      // Same rendezvous — this *is* the paired phone — but a frame sealed with a
      // key that is not the one the row holds. A forgery, not a peer.
      final wrong = await SealedChannel.forDevice(
        deviceKey: SecretKeyData(Uint8List.fromList(List.filled(32, 3))),
        role: ChannelRole.companion,
        generation: 0,
      );
      phone.link.send(
        await wrong.seal(
          Envelope.of(FrameType.sessionsList, seq: 1, id: 'x').toBytes(),
        ),
      );

      await Future.doWhile(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return !logs.any((l) => l.contains('refused a frame'));
      }).timeout(const Duration(seconds: 10));

      // The real phone is still served: one bad frame is not a reason to drop a
      // link that a paired device is holding.
      phone.link.send(
        await phone.channel.seal(
          Envelope.of(FrameType.sessionsList, seq: 2, id: 'r2').toBytes(),
        ),
      );
      expect((await answerTo(phone.answers, 'r2')).id, 'r2');
    },
  );
}
