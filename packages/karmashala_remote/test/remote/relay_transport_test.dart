import 'dart:typed_data';

import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:test/test.dart';

import './transport_harness.dart';

final _rendezvous = RendezvousId.parse('0123456789abcdef0123456789abcdef');
final _other = RendezvousId.parse('fedcba9876543210fedcba9876543210');

void main() {
  late RelayServer relay;
  final closers = <Future<void> Function()>[];

  Future<void> startRelay({int port = 0}) async {
    relay = await RelayServer.bind(address: '127.0.0.1', port: port);
  }

  setUp(() async {
    await startRelay();
    closers.add(() => relay.close());
  });

  tearDown(() async {
    for (final close in closers.reversed) {
      await close();
    }
    closers.clear();
  });

  Uri relayUrl() => Uri.parse('http://127.0.0.1:${relay.port}');

  RelayTransport connect(RendezvousId rendezvous) {
    final transport = RelayTransport(
      endpoint: RelayTransport.endpointFor(relayUrl(), rendezvous),
      backoff: fastBackoff(),
      heartbeat: const Duration(milliseconds: 200),
      connectTimeout: const Duration(seconds: 5),
    )..start();
    closers.add(transport.close);
    return transport;
  }

  test('both ends use the same class and meet at the rendezvous', () async {
    final host = connect(_rendezvous);
    final phone = connect(_rendezvous);
    final toHost = ItemQueue<Uint8List>(host.frames);
    final toPhone = ItemQueue<Uint8List>(phone.frames);
    await StateLog(host).waitFor(TransportState.connected);
    await StateLog(phone).waitFor(TransportState.connected);

    host.send([1, 2, 3]);
    phone.send([9]);

    expect(await toPhone.next, [1, 2, 3]);
    expect(await toHost.next, [9]);
  });

  test('a hundred frames each way arrive in order', () async {
    final host = connect(_rendezvous);
    final phone = connect(_rendezvous);
    final toHost = ItemQueue<Uint8List>(host.frames);
    final toPhone = ItemQueue<Uint8List>(phone.frames);
    await StateLog(phone).waitFor(TransportState.connected);

    for (var i = 0; i < 100; i++) {
      host.send([i]);
      phone.send([255 - i]);
    }

    for (var i = 0; i < 100; i++) {
      expect(await toPhone.next, [i]);
      expect(await toHost.next, [255 - i]);
    }
  });

  test('a megabyte frame survives the relay', () async {
    final host = connect(_rendezvous);
    final phone = connect(_rendezvous);
    final toPhone = ItemQueue<Uint8List>(phone.frames);
    await StateLog(phone).waitFor(TransportState.connected);
    final big = Uint8List.fromList(
      List<int>.generate(1024 * 1024, (i) => i & 0xff),
    );

    host.send(big);

    final got = await toPhone.next;
    expect(got.length, big.length);
    expect(got.sublist(got.length - 8), big.sublist(big.length - 8));
  });

  test('two rendezvous do not see each other', () async {
    final host = connect(_rendezvous);
    final phone = connect(_rendezvous);
    final strangerHost = connect(_other);
    final strangerPhone = connect(_other);
    final toPhone = ItemQueue<Uint8List>(phone.frames);
    final toStranger = ItemQueue<Uint8List>(strangerPhone.frames);
    await StateLog(phone).waitFor(TransportState.connected);
    await StateLog(strangerPhone).waitFor(TransportState.connected);

    host.send([0xaa]);
    strangerHost.send([0xbb]);

    expect(await toPhone.next, [0xaa]);
    expect(await toStranger.next, [0xbb]);
  });

  test('a third client never gets through, and keeps retrying', () async {
    connect(_rendezvous);
    final phone = connect(_rendezvous);
    await StateLog(phone).waitFor(TransportState.connected);

    final gatecrasher = connect(_rendezvous);
    final states = StateLog(gatecrasher);
    await states.waitFor(TransportState.disconnected);
    await states.waitFor(TransportState.connecting);

    expect(states.seen, isNot(contains(TransportState.connected)));
  });

  test('both ends reconnect when the relay restarts', () async {
    final port = relay.port;
    final host = connect(_rendezvous);
    final phone = connect(_rendezvous);
    final toPhone = ItemQueue<Uint8List>(phone.frames);
    final hostStates = StateLog(host);
    final phoneStates = StateLog(phone);
    await hostStates.waitFor(TransportState.connected);
    await phoneStates.waitFor(TransportState.connected);

    await relay.close();
    await hostStates.waitFor(TransportState.disconnected);
    await phoneStates.waitFor(TransportState.disconnected);
    await startRelay(port: port);

    await hostStates.waitFor(TransportState.connected);
    await phoneStates.waitFor(TransportState.connected);
    host.send([7]);

    expect(await toPhone.next, [7]);
  });

  test('what was sent while the relay was down goes out after', () async {
    final port = relay.port;
    final host = connect(_rendezvous);
    final phone = connect(_rendezvous);
    final toPhone = ItemQueue<Uint8List>(phone.frames);
    final hostStates = StateLog(host);
    await hostStates.waitFor(TransportState.connected);

    await relay.close();
    await hostStates.waitFor(TransportState.disconnected);
    host.send([1]);
    host.send([2]);
    await startRelay(port: port);
    await hostStates.waitFor(TransportState.connected);

    expect(await toPhone.next, [1]);
    expect(await toPhone.next, [2]);
  });

  test('a relay that is not there is retried, not given up on', () async {
    final nowhere = RelayTransport(
      endpoint: Uri.parse('ws://127.0.0.1:1/v1/${_rendezvous.value}'),
      backoff: fastBackoff(),
      connectTimeout: const Duration(milliseconds: 300),
    )..start();
    closers.add(nowhere.close);
    final states = StateLog(nowhere);

    await states.waitFor(TransportState.disconnected);
    await states.waitFor(TransportState.connecting);
    await states.waitFor(TransportState.disconnected);

    expect(nowhere.state, isNot(TransportState.closed));
  });

  test('closing stops the reconnect loop for good', () async {
    final host = connect(_rendezvous);
    final states = StateLog(host);
    await states.waitFor(TransportState.connected);

    await host.close();

    expect(host.state, TransportState.closed);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(host.state, TransportState.closed);
    expect(relay.rendezvousCount, 0);
  });

  test('the heartbeat keeps a quiet link alive', () async {
    final host = connect(_rendezvous);
    final phone = connect(_rendezvous);
    final toPhone = ItemQueue<Uint8List>(phone.frames);
    final states = StateLog(host);
    await states.waitFor(TransportState.connected);

    // Several heartbeat intervals with nothing sent.
    await Future<void>.delayed(const Duration(seconds: 1));
    host.send([5]);

    expect(await toPhone.next, [5]);
    expect(states.seen, isNot(contains(TransportState.disconnected)));
  });

  test(
    'closing frees the rendezvous, so the same one can be taken again',
    () async {
      // The defect this pins (found by loop 80's park/return test): closing a
      // `WebSocketChannel`'s sink did not close the socket, so the relay went on
      // counting the departed listener. A host re-registering on the same
      // rendezvous — parking a relay and switching it back on, or moving the
      // relay URL — was then paired **with its own stale socket**, and the phone
      // was refused as a third peer forever.
      final host = connect(_rendezvous);
      final states = StateLog(host);
      await states.waitFor(TransportState.connected);
      expect(relay.rendezvousCount, 1);

      await host.close();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(
        relay.rendezvousCount,
        0,
        reason: 'the relay saw the socket leave',
      );

      // And the rendezvous really is takeable again, by two fresh peers.
      final again = connect(_rendezvous);
      final phone = connect(_rendezvous);
      final toPhone = ItemQueue<Uint8List>(phone.frames);
      again.send([7]);
      expect(await toPhone.next, [7]);
      await states.cancel();
    },
  );

  test('a transport closed while its dial is in flight leaves no socket '
      'behind', () async {
    final host = connect(_rendezvous);
    // No wait: close lands while the WebSocket handshake is still running.
    await host.close();
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(relay.rendezvousCount, 0);
  });
}
