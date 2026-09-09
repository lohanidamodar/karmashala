/// Helpers the transport and conformance tests share.
library;

import 'dart:async';
import 'dart:io';

import 'package:karmashala_remote/remote.dart';
import 'package:flutter_test/flutter_test.dart';

/// A backoff short enough that a reconnect test finishes, long enough that it
/// still goes through the real waiting path.
Backoff fastBackoff() => Backoff(
  initial: const Duration(milliseconds: 20),
  maximum: const Duration(milliseconds: 100),
  jitter: 0,
);

/// Buffers a stream so a test can await items one at a time without racing the
/// next one.
class ItemQueue<T> {
  ItemQueue(Stream<T> stream) {
    _subscription = stream.listen(_items.add);
  }

  final List<T> _items = <T>[];
  late final StreamSubscription<T> _subscription;

  Future<T> get next => nextWithin(const Duration(seconds: 10));

  Future<T> nextWithin(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (_items.isEmpty) {
      if (DateTime.now().isAfter(deadline)) fail('nothing arrived in $timeout');
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    return _items.removeAt(0);
  }

  bool get isEmpty => _items.isEmpty;

  Future<void> cancel() => _subscription.cancel();
}

/// Records a transport's state changes so a test can wait for a *sequence*
/// rather than polling and missing a transition.
class StateLog {
  StateLog(RemoteTransport transport) {
    _subscription = transport.states.listen(seen.add);
  }

  final List<TransportState> seen = <TransportState>[];
  late final StreamSubscription<TransportState> _subscription;
  int _cursor = 0;

  /// Waits for the next [state] at or after the cursor, then moves the cursor
  /// past it, so consecutive calls read a sequence.
  Future<void> waitFor(
    TransportState state, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      for (var i = _cursor; i < seen.length; i++) {
        if (seen[i] == state) {
          _cursor = i + 1;
          return;
        }
      }
      if (DateTime.now().isAfter(deadline)) {
        fail('never reached $state; saw $seen');
      }
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  Future<void> cancel() => _subscription.cancel();
}

/// A beacon port nothing else is listening on, for one test.
///
/// Beacon suites used to share one hard-coded port for the whole file. A
/// beacon is stopped at teardown, but a datagram already in flight does not
/// know that, and the next test's scout — joined to the same group on the same
/// port — hears a host that no longer exists. Dialling that corpse costs the
/// full `attemptTimeout * 4` the pairing race allows a LAN candidate, which is
/// how "Could not find your desktop" reached a run whose desktop was right
/// there, and how a stranger-cooldown assertion saw a second dial it had not
/// asked for. Both are timing, so both come and go under `--concurrency=4`.
///
/// A port per test makes the stale datagram undeliverable rather than merely
/// unlikely: it is addressed to a port no socket in this run has joined.
Future<int> freeBeaconPort() async {
  final probe = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = probe.port;
  probe.close();
  return port;
}
