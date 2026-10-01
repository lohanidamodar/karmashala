import 'dart:async';

import 'package:karmashala_local_ipc/orderly_close.dart';
import 'package:test/test.dart';

/// No socket anywhere here: the order of the three moves is the whole
/// contract, and a real unix socket on Windows is what bugchecked the machine.
void main() {
  group('closeInOrder', () {
    test('half-closes, waits for the peer, and only then closes', () async {
      final end = _FakeEnd();
      final closing = closeInOrder(end, timeout: const Duration(seconds: 5));
      await pumpEventQueue();
      expect(end.calls, ['shutdownSend']);

      end.peerGoes();
      expect(await closing, SocketCloseOutcome.clean);
      expect(end.calls, ['shutdownSend', 'destroy']);
    });

    test(
      'a peer that went first is closed at once, with no half-close',
      () async {
        final end = _FakeEnd()..peerGoes();
        expect(await closeInOrder(end), SocketCloseOutcome.afterPeer);
        expect(end.calls, ['destroy']);
      },
    );

    test('a peer that never answers is left open, not closed', () async {
      final end = _FakeEnd();
      final outcome = await closeInOrder(
        end,
        timeout: const Duration(milliseconds: 20),
      );
      expect(outcome, SocketCloseOutcome.leftToOs);
      expect(end.calls, ['shutdownSend']);
    });

    test('one left open is closed once its peer does go', () async {
      final end = _FakeEnd();
      await closeInOrder(end, timeout: const Duration(milliseconds: 20));
      end.peerGoes();
      await pumpEventQueue();
      expect(end.calls, ['shutdownSend', 'destroy']);
    });

    test('a half-close that throws still waits for the peer', () async {
      final end = _FakeEnd()..shutdownThrows = true;
      final closing = closeInOrder(end, timeout: const Duration(seconds: 5));
      await pumpEventQueue();
      expect(end.calls, ['shutdownSend']);
      end.peerGoes();
      expect(await closing, SocketCloseOutcome.clean);
      expect(end.calls.last, 'destroy');
    });

    test(
      'a half-close that never finishes is bounded by the same timeout',
      () async {
        final end = _FakeEnd()..shutdownHangs = true;
        final outcome = await closeInOrder(
          end,
          timeout: const Duration(milliseconds: 20),
        );
        expect(outcome, SocketCloseOutcome.leftToOs);
        expect(end.calls, ['shutdownSend']);
      },
    );

    test('a peer that answers while the half-close is still flushing is '
        'closed at once', () async {
      final end = _FakeEnd()..shutdownHangs = true;
      final closing = closeInOrder(end, timeout: const Duration(seconds: 30));
      await pumpEventQueue();
      end.peerGoes();
      expect(
        await closing.timeout(const Duration(seconds: 5)),
        SocketCloseOutcome.clean,
      );
      expect(end.calls, ['shutdownSend', 'destroy']);
    });
  });

  group('UnixSocketRegistry', () {
    test('settles every open socket and counts clean against left', () async {
      final registry = UnixSocketRegistry(orderly: true);
      final clean = _FakeSocket(registry, SocketCloseOutcome.clean);
      final afterPeer = _FakeSocket(registry, SocketCloseOutcome.afterPeer);
      final silent = _FakeSocket(registry, SocketCloseOutcome.leftToOs);
      for (final s in [clean, afterPeer, silent]) {
        registry.add(s);
      }

      final settled = await registry.settleAll();
      expect((settled.clean, settled.leftToOs), (2, 1));
      expect([clean, afterPeer, silent].every((s) => s.closes == 1), isTrue);
      expect(registry.openCount, 0);
    });

    test(
      'a socket left earlier and never answered is still counted as left',
      () async {
        final registry = UnixSocketRegistry(orderly: true);
        final silent = _FakeSocket(registry, SocketCloseOutcome.leftToOs);
        registry.add(silent);
        await silent.close();

        final settled = await registry.settleAll();
        expect((settled.clean, settled.leftToOs), (0, 1));
        expect(silent.closes, 1, reason: 'not closed a second time');
      },
    );

    test(
      'waits out the grace after the last close, and not without one',
      () async {
        final registry = UnixSocketRegistry(orderly: true);
        final idle = Stopwatch()..start();
        await registry.afterLastClose(const Duration(seconds: 5));
        expect(idle.elapsed, lessThan(const Duration(seconds: 1)));

        final socket = _FakeSocket(registry, SocketCloseOutcome.clean);
        registry.add(socket);
        await socket.close();
        final waited = Stopwatch()..start();
        await registry.afterLastClose(const Duration(milliseconds: 50));
        expect(
          waited.elapsed,
          greaterThanOrEqualTo(const Duration(milliseconds: 30)),
        );
      },
    );

    test('not Windows: nothing is tracked and settling does nothing', () async {
      final registry = UnixSocketRegistry(orderly: false);
      registry.add(_FakeSocket(registry, SocketCloseOutcome.clean));
      expect(registry.openCount, 0);
      expect(await settleUnixSockets(registry: registry), isNull);
    });

    test('settleUnixSockets logs one line', () async {
      final registry = UnixSocketRegistry(orderly: true);
      final socket = _FakeSocket(registry, SocketCloseOutcome.leftToOs);
      registry.add(socket);
      final lines = <String>[];
      await settleUnixSockets(
        registry: registry,
        log: lines.add,
        grace: Duration.zero,
      );
      expect(lines, [
        'unix sockets at exit: 0 closed cleanly, 1 left to the OS',
      ]);
    });
  });
}

class _FakeEnd implements OrderlyEnd {
  final calls = <String>[];
  final _peer = Completer<void>();
  var shutdownThrows = false;
  var shutdownHangs = false;

  void peerGoes() {
    if (!_peer.isCompleted) _peer.complete();
  }

  @override
  bool get peerEnded => _peer.isCompleted;

  @override
  Future<void> get peerEnd => _peer.future;

  @override
  Future<void> shutdownSend() async {
    calls.add('shutdownSend');
    if (shutdownThrows) throw StateError('the sink is bound');
    if (shutdownHangs) await Completer<void>().future;
  }

  @override
  void destroy() => calls.add('destroy');
}

class _FakeSocket implements SettlesOnExit {
  _FakeSocket(this._registry, this._outcome);

  final UnixSocketRegistry _registry;
  final SocketCloseOutcome _outcome;
  var closes = 0;
  Future<SocketCloseOutcome>? _closing;

  @override
  Future<SocketCloseOutcome> close() => _closing ??= () async {
    closes++;
    _registry.closed(this, _outcome);
    return _outcome;
  }();
}
