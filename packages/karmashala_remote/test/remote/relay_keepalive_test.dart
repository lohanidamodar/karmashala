/// A host's relay listeners, and what they cost a relay nobody is using.
///
/// The failure behind this file: a shared relay drops a lone socket after two
/// minutes, the listener redialled a second later, and a host holds one
/// listener per paired device per generation in its window. Eighteen of them
/// made an upgrade every seven seconds, all day, with no phone anywhere —
/// some ninety thousand requests a day against a hosted relay's free tier.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:karmashala_relay_protocol/karmashala_relay_protocol.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

import './transport_harness.dart';

final _rendezvous = RendezvousId.parse('0123456789abcdef0123456789abcdef');

/// A stand-in relay that upgrades every socket and hands it to [onSocket].
Future<Uri> _relayThat(void Function(WebSocket socket) onSocket) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    onSocket(await WebSocketTransformer.upgrade(request));
  });
  return Uri.parse('http://127.0.0.1:${server.port}');
}

/// The waits a transport announced between its dials, in milliseconds.
List<int> _waits(List<String> log) => [
  for (final line in log)
    if (RegExp(r'^reconnecting in (\d+)ms$').firstMatch(line) case final m?)
      int.parse(m.group(1)!),
];

Backoff _steps() => Backoff(
  initial: const Duration(milliseconds: 20),
  maximum: const Duration(milliseconds: 320),
  jitter: 0,
);

void main() {
  group('a listener on a relay with a lone timeout', () {
    late RelayServer relay;

    setUp(() async {
      relay = await RelayServer.bind(
        address: '127.0.0.1',
        port: 0,
        options: const RelayOptions(loneTimeout: Duration(milliseconds: 200)),
      );
      addTearDown(relay.close);
    });

    RelayTransport open({required bool keepAlive}) {
      final transport = RelayTransport(
        endpoint: RelayTransport.endpointFor(
          Uri.parse('http://127.0.0.1:${relay.port}'),
          _rendezvous,
        ),
        backoff: fastBackoff(),
        keepAlive: keepAlive,
        keepAliveInterval: const Duration(milliseconds: 50),
      )..start();
      addTearDown(transport.close);
      return transport;
    }

    test('stays on its one connection while no peer is coming', () async {
      final listener = open(keepAlive: true);
      final states = StateLog(listener);
      await states.waitFor(TransportState.connected);

      // Six lone timeouts with nobody there.
      await Future<void>.delayed(const Duration(milliseconds: 1200));

      expect(
        states.seen.where((s) => s == TransportState.connected),
        hasLength(1),
        reason: 'the relay never sent it away, so it never redialled',
      );
      expect(listener.state, TransportState.connected);
      expect(relay.rendezvousCount, 1);
      await states.cancel();
    });

    test('and still meets the peer that does arrive', () async {
      final listener = open(keepAlive: true);
      final toListener = ItemQueue<Uint8List>(listener.frames);
      await StateLog(listener).waitFor(TransportState.connected);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final phone = open(keepAlive: false);
      final toPhone = ItemQueue<Uint8List>(phone.frames);
      phone.send([1]);
      listener.send([2]);

      expect(await toListener.next, [1]);
      expect(await toPhone.next, [2]);
      // The heartbeat is the relay's and the listener's alone: no ping
      // reached the phone and no pong reached either as a frame.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(toListener.isEmpty, isTrue);
      expect(toPhone.isEmpty, isTrue);
    });

    test('an end that dials for a peer who is not there is sent away', () async {
      // The phone's side of the same class: it expects its peer now, so
      // alone it hears "no peer" rather than waiting for ever.
      final dialler = open(keepAlive: false);
      final states = StateLog(dialler);
      await states.waitFor(TransportState.connected);
      await states.waitFor(TransportState.disconnected);

      expect(dialler.lastCloseCode, kCloseNoPeer);
      await states.cancel();
    });
  });

  group('a relay that predates the heartbeat', () {
    test('is pinged once per connection, then left alone', () async {
      final texts = <String>[];
      final relay = await _relayThat((socket) {
        socket.listen((message) {
          if (message is String) texts.add(message);
        });
      });
      final listener = RelayTransport(
        endpoint: RelayTransport.endpointFor(relay, _rendezvous),
        backoff: fastBackoff(),
        keepAlive: true,
        keepAliveInterval: const Duration(milliseconds: 40),
      )..start();
      addTearDown(listener.close);
      final states = StateLog(listener);
      await states.waitFor(TransportState.connected);

      // Ten intervals: an old relay holds each ping as a frame for the
      // peer, and hangs up on a lone socket that sends more than eight.
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(texts, [kRelayPing]);
      expect(listener.state, TransportState.connected);
      await states.cancel();
    });

    test('a peer\'s ping it passed on is not a frame', () async {
      final relay = await _relayThat((socket) {
        socket.add(kRelayPing);
        socket.add(kRelayPong);
        socket.add([9]);
      });
      final log = <String>[];
      final dialler = RelayTransport(
        endpoint: RelayTransport.endpointFor(relay, _rendezvous),
        backoff: fastBackoff(),
        onLog: log.add,
      )..start();
      addTearDown(dialler.close);

      expect(await ItemQueue<Uint8List>(dialler.frames).next, [9]);
      expect(log.where((line) => line.contains('non-binary')), isEmpty);
    });
  });

  group('the reconnect schedule', () {
    RelayTransport dial(Uri relay, List<String> log, {Duration? stableAfter}) {
      final transport = RelayTransport(
        endpoint: RelayTransport.endpointFor(relay, _rendezvous),
        backoff: _steps(),
        stableAfter: stableAfter ?? kLinkStableAfter,
        onLog: log.add,
      )..start();
      addTearDown(transport.close);
      return transport;
    }

    Future<void> untilWaits(List<String> log, int count) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (_waits(log).length < count) {
        if (DateTime.now().isAfter(deadline)) {
          fail('only ${_waits(log)} after ten seconds');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    test('a relay that takes the socket and hangs up at once is dialled less '
        'and less often', () async {
      // Taking the socket proves nothing: a relay upgrades anyone. Resetting
      // the backoff there made this a dial a second, for ever.
      var sockets = 0;
      final relay = await _relayThat((socket) {
        sockets++;
        socket.close(kCloseBusy, 'rendezvous busy');
      });
      final log = <String>[];
      dial(relay, log);

      await untilWaits(log, 7);

      expect(_waits(log).take(7), [20, 40, 80, 160, 320, 320, 320]);
      expect(sockets, greaterThanOrEqualTo(7));
    });

    test('a link the peer spoke on is redialled from the first step', () async {
      final relay = await _relayThat((socket) {
        socket.add([1]);
        socket.close(kClosePeerLeft, 'peer left');
      });
      final log = <String>[];
      final transport = dial(relay, log);
      final frames = ItemQueue<Uint8List>(transport.frames);

      await untilWaits(log, 4);

      expect(_waits(log).take(4), [20, 20, 20, 20]);
      expect(await frames.next, [1]);
    });

    test('and so is one that held, though nobody spoke on it', () async {
      // A listener a relay sends away after its lone timeout: the connection
      // worked for as long as it was allowed to.
      final relay = await _relayThat((socket) {
        Timer(
          const Duration(milliseconds: 150),
          () => socket.close(kCloseNoPeer, 'no peer'),
        );
      });
      final log = <String>[];
      dial(relay, log, stableAfter: const Duration(milliseconds: 100));

      await untilWaits(log, 3);

      expect(_waits(log).take(3), [20, 20, 20]);
    });

    test('a relay that is not there still backs off', () async {
      final gone = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = gone.port;
      await gone.close();
      final log = <String>[];
      dial(Uri.parse('http://127.0.0.1:$port'), log);

      await untilWaits(log, 4);

      expect(_waits(log).take(4), [20, 40, 80, 160]);
    });
  });
}
