import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala/src/features/remote/transport/lan_transport.dart';
import 'package:karmashala/src/features/remote/transport/remote_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'transport_harness.dart';

void main() {
  late LanTransportServer server;
  final closers = <Future<void> Function()>[];

  setUp(() async {
    server = await LanTransportServer.bind(address: '127.0.0.1', port: 0);
    closers.add(server.close);
  });

  tearDown(() async {
    for (final close in closers.reversed) {
      await close();
    }
    closers.clear();
  });

  LanTransport dial({int? maxQueuedFrames, bool start = true}) {
    final transport = LanTransport(
      host: '127.0.0.1',
      port: server.port,
      backoff: fastBackoff(),
      maxQueuedFrames: maxQueuedFrames ?? 256,
    );
    closers.add(transport.close);
    if (start) transport.start();
    return transport;
  }

  test('a phone dials in and frames go both ways', () async {
    final links = ItemQueue<LanLink>(server.connections);
    final phone = dial();
    final states = StateLog(phone);
    final host = await links.next;
    final fromPhone = ItemQueue<Uint8List>(host.frames);
    final fromHost = ItemQueue<Uint8List>(phone.frames);
    await states.waitFor(TransportState.connected);

    phone.send([1, 2, 3]);
    host.send([9]);

    expect(await fromPhone.next, [1, 2, 3]);
    expect(await fromHost.next, [9]);
  });

  test('a hundred frames arrive in order', () async {
    final links = ItemQueue<LanLink>(server.connections);
    final phone = dial();
    final states = StateLog(phone);
    final host = await links.next;
    final fromPhone = ItemQueue<Uint8List>(host.frames);
    await states.waitFor(TransportState.connected);

    for (var i = 0; i < 100; i++) {
      phone.send([i & 0xff, (i >> 8) & 0xff]);
    }

    for (var i = 0; i < 100; i++) {
      expect(await fromPhone.next, [i & 0xff, (i >> 8) & 0xff]);
    }
  });

  test('a megabyte frame crosses whole', () async {
    final links = ItemQueue<LanLink>(server.connections);
    final phone = dial();
    final states = StateLog(phone);
    final host = await links.next;
    final fromPhone = ItemQueue<Uint8List>(host.frames);
    await states.waitFor(TransportState.connected);
    final big = Uint8List.fromList(
      List<int>.generate(1024 * 1024, (i) => i & 0xff),
    );

    phone.send(big);

    final got = await fromPhone.next;
    expect(got.length, big.length);
    expect(got.sublist(0, 8), big.sublist(0, 8));
    expect(got.sublist(got.length - 8), big.sublist(big.length - 8));
  });

  test('refuses to send a frame over the cap', () async {
    final phone = dial();

    expect(
      () => phone.send(Uint8List(kMaxTransportFrameBytes + 1)),
      throwsA(isA<TransportException>()),
    );
  });

  test('the phone redials when the link drops', () async {
    final links = ItemQueue<LanLink>(server.connections);
    final phone = dial();
    final states = StateLog(phone);
    final first = await links.next;
    await states.waitFor(TransportState.connected);

    await first.close();

    await states.waitFor(TransportState.disconnected);
    await states.waitFor(TransportState.connected);
    final second = await links.next;
    final fromPhone = ItemQueue<Uint8List>(second.frames);
    phone.send([42]);

    expect(await fromPhone.next, [42]);
    expect(identical(first, second), isFalse);
  });

  test('what was sent while down goes out on the next link', () async {
    final links = ItemQueue<LanLink>(server.connections);
    final phone = dial();
    final states = StateLog(phone);
    final first = await links.next;
    await states.waitFor(TransportState.connected);

    await first.close();
    await states.waitFor(TransportState.disconnected);
    phone.send([7]);
    phone.send([8]);

    final second = await links.next;
    final fromPhone = ItemQueue<Uint8List>(second.frames);
    expect(await fromPhone.next, [7]);
    expect(await fromPhone.next, [8]);
  });

  test('the outbound queue is bounded, oldest dropped first', () async {
    final links = ItemQueue<LanLink>(server.connections);
    final phone = dial(maxQueuedFrames: 3, start: false);

    for (var i = 0; i < 6; i++) {
      phone.send([i]);
    }

    expect(phone.droppedFrames, 3);
    phone.start();
    final host = await links.next;
    final fromPhone = ItemQueue<Uint8List>(host.frames);
    expect(await fromPhone.next, [3]);
    expect(await fromPhone.next, [4]);
    expect(await fromPhone.next, [5]);
  });

  test('a closed transport stays closed', () async {
    final phone = dial();
    final states = StateLog(phone);
    await states.waitFor(TransportState.connected);

    await phone.close();

    expect(phone.state, TransportState.closed);
    expect(phone.isConnected, isFalse);
    expect(() => phone.send([1]), throwsA(isA<TransportException>()));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(phone.state, TransportState.closed);
  });

  test('a link the host closes ends that link for good', () async {
    final links = ItemQueue<LanLink>(server.connections);
    dial();
    final host = await links.next;

    await host.close();

    expect(host.state, TransportState.closed);
  });

  test('a peer whose framing is nonsense is dropped, not buffered', () async {
    final links = ItemQueue<LanLink>(server.connections);
    final socket = await Socket.connect('127.0.0.1', server.port);
    final link = await links.next;
    final states = StateLog(link);
    await states.waitFor(TransportState.connected);

    // A length prefix claiming 2 GiB, which no sealed frame can be.
    final header = Uint8List(4);
    ByteData.view(header.buffer).setUint32(0, 0x7fffffff);
    socket.add(header);
    await socket.flush();

    await states.waitFor(TransportState.closed);
    socket.destroy();
  });

  test('the listener reports where it bound', () {
    expect(server.port, greaterThan(0));
    expect(server.address.address, '127.0.0.1');
  });

  test('it keeps two phones apart', () async {
    final links = ItemQueue<LanLink>(server.connections);
    final phoneA = dial();
    final hostA = await links.next;
    final phoneB = dial();
    final hostB = await links.next;
    final fromA = ItemQueue<Uint8List>(hostA.frames);
    final fromB = ItemQueue<Uint8List>(hostB.frames);
    final toA = ItemQueue<Uint8List>(phoneA.frames);
    final toB = ItemQueue<Uint8List>(phoneB.frames);

    phoneA.send([0xaa]);
    phoneB.send([0xbb]);
    hostA.send([1]);
    hostB.send([2]);

    expect(await fromA.next, [0xaa]);
    expect(await fromB.next, [0xbb]);
    expect(await toA.next, [1]);
    expect(await toB.next, [2]);
  });
}
