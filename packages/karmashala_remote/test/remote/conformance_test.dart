/// One scenario, run over the direct LAN path and over the relay path.
///
/// Anything that passes here is true of the transport the companion will use at
/// home and of the one it will use from mobile data, which is the whole point of
/// keeping the sealing above the transport.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

import './transport_harness.dart';

/// A string that must never appear on the wire.
const String kMarker = 'PLAINTEXT-MUST-NOT-CROSS-THE-WIRE';

final _pairingSecret = Uint8List.fromList(
  List<int>.generate(32, (i) => 0x40 + i),
);
final _hostId = DeviceId.parse('11111111222222223333333344444444');
final _phoneId = DeviceId.parse('aaaaaaaabbbbbbbbccccccccdddddddd');

/// One end: a sealed channel that outlives the socket under it.
class Endpoint {
  Endpoint(this.channel);

  final SealedChannel channel;
  RemoteTransport? _transport;
  ItemQueue<Uint8List>? _frames;

  /// Everything this end received off the wire, still sealed.
  final List<Uint8List> wireFrames = <Uint8List>[];

  /// Points the endpoint at a (new) transport. The channel is untouched: its
  /// lifetime is the pairing generation, not the connection.
  void attach(RemoteTransport transport) {
    _transport = transport;
    _frames = ItemQueue<Uint8List>(transport.frames);
  }

  Future<Uint8List> send(FrameType type, Map<String, Object?> payload) async {
    final envelope = Envelope.of(
      type,
      seq: channel.nextSendSequence,
      payload: payload,
    );
    final sealed = await channel.seal(envelope.toBytes());
    _transport!.send(sealed);
    return sealed;
  }

  Future<Envelope> receive() async {
    final frame = await _frames!.next;
    wireFrames.add(frame);
    final opened = await channel.unseal(frame);
    final envelope = Envelope.fromBytes(opened.plaintext);
    expect(
      envelope.seq,
      opened.sequence,
      reason: 'the envelope seq is the sealed sequence',
    );
    return envelope;
  }

  /// Puts a frame back on the wire by hand, as an attacker would.
  void replay(Uint8List frame) => _transport!.send(frame);

  Future<Uint8List> nextRawFrame() async {
    final frame = await _frames!.next;
    wireFrames.add(frame);
    return frame;
  }
}

/// What a transport must provide for the scenario to run over it.
abstract class Fixture {
  String get name;

  Future<void> start();

  Endpoint get host;
  Endpoint get phone;

  /// Breaks the link the way the world breaks it, and returns once both ends
  /// are carrying frames again.
  Future<void> breakAndHeal();

  Future<void> stop();
}

class LanFixture implements Fixture {
  @override
  String get name => 'over the direct LAN path';

  late LanTransportServer _server;
  late ItemQueue<LanLink> _links;
  late LanTransport _phoneTransport;
  late LanLink _currentLink;

  @override
  late Endpoint host;
  @override
  late Endpoint phone;

  @override
  Future<void> start() async {
    final channels = await pairedChannels();
    host = Endpoint(channels.$1);
    phone = Endpoint(channels.$2);

    _server = await LanTransportServer.bind(address: '127.0.0.1', port: 0);
    _links = ItemQueue<LanLink>(_server.connections);
    _phoneTransport = LanTransport(
      host: '127.0.0.1',
      port: _server.port,
      backoff: fastBackoff(),
    )..start();
    phone.attach(_phoneTransport);
    _currentLink = await _links.next;
    host.attach(_currentLink);
    await StateLog(_phoneTransport).waitFor(TransportState.connected);
  }

  @override
  Future<void> breakAndHeal() async {
    final states = StateLog(_phoneTransport);
    await _currentLink.close();
    await states.waitFor(TransportState.disconnected);
    await states.waitFor(TransportState.connected);
    _currentLink = await _links.next;
    // The phone redialled, so the host's socket is new — but its sealed
    // channel is not, which is what carries the sequence across.
    host.attach(_currentLink);
    await states.cancel();
  }

  @override
  Future<void> stop() async {
    await _phoneTransport.close();
    await _server.close();
  }
}

class RelayFixture implements Fixture {
  @override
  String get name => 'over the relay';

  late RelayServer _relay;
  late int _port;
  late RelayTransport _hostTransport;
  late RelayTransport _phoneTransport;

  @override
  late Endpoint host;
  @override
  late Endpoint phone;

  @override
  Future<void> start() async {
    final channels = await pairedChannels();
    host = Endpoint(channels.$1);
    phone = Endpoint(channels.$2);

    _relay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    _port = _relay.port;

    final rendezvous = await rendezvousFor(await deviceKey(), 0);
    final url = Uri.parse('http://127.0.0.1:$_port');
    _hostTransport = RelayTransport(
      endpoint: RelayTransport.endpointFor(url, rendezvous),
      backoff: fastBackoff(),
      heartbeat: const Duration(milliseconds: 500),
    )..start();
    _phoneTransport = RelayTransport(
      endpoint: RelayTransport.endpointFor(url, rendezvous),
      backoff: fastBackoff(),
      heartbeat: const Duration(milliseconds: 500),
    )..start();
    host.attach(_hostTransport);
    phone.attach(_phoneTransport);
    await StateLog(_hostTransport).waitFor(TransportState.connected);
    await StateLog(_phoneTransport).waitFor(TransportState.connected);
  }

  @override
  Future<void> breakAndHeal() async {
    final hostStates = StateLog(_hostTransport);
    final phoneStates = StateLog(_phoneTransport);
    await _relay.close();
    await hostStates.waitFor(TransportState.disconnected);
    await phoneStates.waitFor(TransportState.disconnected);
    _relay = await RelayServer.bind(address: '127.0.0.1', port: _port);
    await hostStates.waitFor(TransportState.connected);
    await phoneStates.waitFor(TransportState.connected);
    // Both transports are the same objects; only the sockets under them moved.
    await hostStates.cancel();
    await phoneStates.cancel();
  }

  @override
  Future<void> stop() async {
    await _hostTransport.close();
    await _phoneTransport.close();
    await _relay.close();
  }
}

Future<SecretKeyData> deviceKey() => deriveDeviceKey(
  pairingSecret: _pairingSecret,
  hostId: _hostId,
  deviceId: _phoneId,
);

/// The two ends of one pairing, as Loop A will build them.
Future<(SealedChannel, SealedChannel)> pairedChannels() async {
  final key = await deviceKey();
  return (
    await SealedChannel.forDevice(deviceKey: key, role: ChannelRole.host),
    await SealedChannel.forDevice(deviceKey: key, role: ChannelRole.companion),
  );
}

void main() {
  final fixtures = <String, Fixture Function()>{
    'over the direct LAN path': LanFixture.new,
    'over the relay': RelayFixture.new,
  };

  fixtures.forEach((name, build) {
    group(name, () {
      late Fixture current;

      setUp(() async {
        current = build();
        await current.start();
      });

      tearDown(() async => current.stop());

      test('a hundred sealed frames each way, in order', () async {
        for (var i = 0; i < 100; i++) {
          await current.host.send(FrameType.sessionChanged, {
            'sessionId': 's$i',
            'note': kMarker,
          });
          await current.phone.send(FrameType.promptSend, {
            'sessionId': 's$i',
            'text': kMarker,
          });
        }

        for (var i = 0; i < 100; i++) {
          final atPhone = await current.phone.receive();
          expect(atPhone.knownType, FrameType.sessionChanged);
          expect(atPhone.seq, i);
          expect(atPhone.payload['sessionId'], 's$i');

          final atHost = await current.host.receive();
          expect(atHost.knownType, FrameType.promptSend);
          expect(atHost.seq, i);
        }

        expect(current.host.channel.highestReceivedSequence, 99);
        expect(current.phone.channel.highestReceivedSequence, 99);
      });

      test('nothing readable crosses the wire', () async {
        await current.host.send(FrameType.transcriptAppended, {
          'text': kMarker,
        });

        final frame = await current.phone.nextRawFrame();

        expect(
          latin1.decode(frame, allowInvalid: true),
          isNot(contains(kMarker)),
        );
        expect(
          latin1.decode(frame, allowInvalid: true),
          isNot(contains('transcript.appended')),
        );
        expect(frame.length, greaterThan(kSealedFrameOverhead));
      });

      test('a replayed frame is refused', () async {
        final sealed = await current.host.send(FrameType.approvalRequested, {
          'approvalId': 'a1',
        });
        await current.phone.receive();

        current.host.replay(sealed);

        final again = await current.phone.nextRawFrame();
        expect(again, sealed, reason: 'the transport delivered it happily');
        await expectLater(
          current.phone.channel.unseal(again),
          throwsA(isA<ReplayedFrameException>()),
        );
      });

      test('the link drops and the sequence carries on', () async {
        await current.host.send(FrameType.hostStatus, {'v': 1});
        expect((await current.phone.receive()).seq, 0);

        await current.breakAndHeal();

        await current.host.send(FrameType.sessionChanged, {'sessionId': 's1'});
        await current.phone.send(FrameType.sessionsList, const {});

        final atPhone = await current.phone.receive();
        final atHost = await current.host.receive();
        expect(atPhone.seq, 1, reason: 'the host kept counting');
        expect(atHost.seq, 0, reason: 'the phone had sent nothing before');
        expect(current.host.channel.nextSendSequence, 2);
      });

      test(
        'a frame from before the drop cannot be replayed after it',
        () async {
          final sealed = await current.host.send(FrameType.hostStatus, {
            'v': 1,
          });
          await current.phone.receive();

          await current.breakAndHeal();
          current.host.replay(sealed);

          final again = await current.phone.nextRawFrame();
          await expectLater(
            current.phone.channel.unseal(again),
            throwsA(isA<ReplayedFrameException>()),
          );
        },
      );

      test('a frame sealed for another pairing is refused', () async {
        final stranger = await SealedChannel.forDevice(
          deviceKey: await deriveDeviceKey(
            pairingSecret: _pairingSecret,
            hostId: _hostId,
            deviceId: DeviceId.parse('99' * 16),
          ),
          role: ChannelRole.host,
        );
        final forged = await stranger.seal(
          Envelope.of(FrameType.hostStatus, seq: 0).toBytes(),
        );

        current.host.replay(forged);

        await expectLater(
          current.phone.channel.unseal(await current.phone.nextRawFrame()),
          throwsA(isA<SealedFrameException>()),
        );
      });
    });
  });
}
