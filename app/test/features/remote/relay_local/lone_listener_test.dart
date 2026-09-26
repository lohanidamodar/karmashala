/// The desktop's own relay must not hang up on the desktop.
///
/// Measured on the owner's machine while it was failing: the app holds three
/// rendezvous listeners on its embedded local relay (one per generation in
/// `kHostRelayListenWindow`), and every one of them was being evicted and
/// re-dialled every 120.3 seconds — the relay package's two-minute lone
/// timeout — 58 times and counting in a single run. `/healthz` said
/// `{"rendezvous":3,"sockets":3}` with all three sockets owned by the app
/// itself, and the app log was nothing but
///
///   17:41:36.269 I remote: a socket is waiting (3 held)
///   17:43:36.572 I remote: a socket is waiting (3 held)
///   17:45:36.837 I remote: a socket is waiting (3 held)
///
/// for forty minutes.
///
/// The lone timeout is right for a SHARED relay, where a socket waiting alone
/// may be a stranger pinning a rendezvous nobody will ever come to. On the
/// relay embedded in the desktop there are no strangers: every waiting socket
/// is one of that desktop's own listeners, waiting — correctly — for a phone
/// that may be away for hours. Evicting them buys nothing and costs a window,
/// every two minutes per generation, in which the desktop is not at its own
/// rendezvous and a phone arriving finds nobody there.
library;

import 'dart:typed_data';

import 'package:karmashala/src/features/remote/relay_local/local_relay_service.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:karmashala_relay_protocol/karmashala_relay_protocol.dart'
    show kCloseNoPeer;
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/io.dart';

void main() {
  test('the local relay is configured to leave a waiting listener alone', () {
    expect(
      kLocalRelayLoneTimeout,
      Duration.zero,
      reason:
          'a lone socket on the embedded relay is the desktop itself, and '
          'hanging up on it every two minutes is the app evicting its own '
          'listener',
    );
  });

  test('a socket waiting alone is not hung up on', () async {
    final relay = await RelayServer.bind(
      address: '127.0.0.1',
      port: 0,
      options: const RelayOptions(loneTimeout: kLocalRelayLoneTimeout),
    );
    addTearDown(relay.close);

    final listener = IOWebSocketChannel.connect(
      Uri.parse(
        'ws://127.0.0.1:${relay.port}/v1/'
        '0123456789abcdef0123456789abcdef',
      ),
    );
    await listener.ready;
    final hungUpOn = listener.stream.drain<void>().then((_) => true);

    // Long past any lone timeout a shared relay would apply, scaled down: the
    // point is that no timer exists, not that a particular one is long.
    final evicted = await hungUpOn.timeout(
      const Duration(milliseconds: 600),
      onTimeout: () => false,
    );

    expect(evicted, isFalse, reason: 'the desktop is left waiting, as asked');
    expect(relay.rendezvousCount, 1);
    await listener.sink.close();
  });

  test('and the phone still meets it there long after that timeout would '
      'have fired', () async {
    final relay = await RelayServer.bind(
      address: '127.0.0.1',
      port: 0,
      options: const RelayOptions(loneTimeout: kLocalRelayLoneTimeout),
    );
    addTearDown(relay.close);
    Uri url() => Uri.parse(
      'ws://127.0.0.1:${relay.port}/v1/0123456789abcdef0123456789abcdef',
    );

    // The desktop takes its place and waits.
    final host = IOWebSocketChannel.connect(url());
    await host.ready;
    await Future<void>.delayed(const Duration(milliseconds: 500));

    // The phone comes back after being away.
    final phone = IOWebSocketChannel.connect(url());
    await phone.ready;
    host.sink.add(Uint8List.fromList([7]));

    expect(
      await phone.stream.first.timeout(const Duration(seconds: 5)),
      [7],
      reason: 'the desktop was still at the rendezvous when the phone arrived',
    );
    await phone.sink.close();
    await host.sink.close();
  });

  test(
    'a shared relay keeps its lone timeout — this is the local relay only',
    () async {
      final relay = await RelayServer.bind(
        address: '127.0.0.1',
        port: 0,
        options: const RelayOptions(loneTimeout: Duration(milliseconds: 150)),
      );
      addTearDown(relay.close);

      final stranger = IOWebSocketChannel.connect(
        Uri.parse(
          'ws://127.0.0.1:${relay.port}/v1/'
          'fedcba9876543210fedcba9876543210',
        ),
      );
      await stranger.ready;
      await stranger.stream.drain<void>();

      expect(stranger.closeCode, kCloseNoPeer);
      expect(relay.rendezvousCount, 0);
    },
  );
}
