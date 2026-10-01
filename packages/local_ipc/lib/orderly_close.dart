/// Closing unix domain sockets so that no process exits with a close pending.
///
/// On Windows dart:io closes every socket with `DisconnectEx(TF_REUSE_SOCKET)`,
/// which afunix.sys keeps pending until the peer has closed too, and a process
/// that exits with one pending bugchecks the machine (0xD1). So there the side
/// that goes half-closes, waits for the peer's end-of-file, and only then
/// closes: the peer has closed by then, and the disconnect completes at once.
/// docs/SETTLED.md, "A unix socket on Windows is closed in order".
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// How long a close waits for the peer's end-of-file.
const Duration kOrderlyCloseTimeout = Duration(seconds: 2);

/// How long an exit waits after the last close, for its disconnect to finish.
const Duration kSocketSettleGrace = Duration(milliseconds: 50);

/// How one close ended.
enum SocketCloseOutcome {
  /// Half-closed, the peer answered with end-of-file, then closed.
  clean,

  /// The peer had gone first; closed at once.
  afterPeer,

  /// The peer did not answer in time, so the socket was not closed. A close
  /// now would leave a disconnect pending for the exit to cancel; an open
  /// handle is closed by process teardown with nothing pending. If the peer
  /// does go later, the socket is closed then.
  leftToOs,

  /// Not Windows: closed at once, as it always was.
  immediate,
}

/// The three moves an orderly close makes, so the order is testable without
/// a socket.
abstract interface class OrderlyEnd {
  /// Whether the peer's end-of-file (or an error) has been seen.
  bool get peerEnded;

  /// Completes when [peerEnded] becomes true; never completes with an error.
  Future<void> get peerEnd;

  /// Flushes, then half-closes the send direction: a plain `shutdown`, which
  /// leaves nothing pending.
  Future<void> shutdownSend();

  /// Closes the handle.
  void destroy();
}

/// Closes [end] in order: half-close, wait up to [timeout] for the peer's
/// end-of-file, then close — or, when the peer never answers, leave it open.
Future<SocketCloseOutcome> closeInOrder(
  OrderlyEnd end, {
  Duration timeout = kOrderlyCloseTimeout,
}) async {
  if (end.peerEnded) {
    end.destroy();
    return SocketCloseOutcome.afterPeer;
  }
  final clock = Stopwatch()..start();
  try {
    // The peer going ends a flush it will never read.
    await Future.any([end.shutdownSend(), end.peerEnd]).timeout(timeout);
  } on Object {
    // A send that cannot finish still leaves the peer's answer to wait for.
  }
  var answered = end.peerEnded;
  final left = timeout - clock.elapsed;
  if (!answered && left > Duration.zero) {
    answered = await end.peerEnd
        .then((_) => true)
        .timeout(left, onTimeout: () => false);
  }
  if (!answered) {
    unawaited(end.peerEnd.then((_) => end.destroy()));
    return SocketCloseOutcome.leftToOs;
  }
  end.destroy();
  return SocketCloseOutcome.clean;
}

/// Something an exit settles first: an [OrderlySocket], or a test's fake.
abstract interface class SettlesOnExit {
  Future<SocketCloseOutcome> close();
}

/// What [settleUnixSockets] found: one line for the exit's log.
class UnixSocketsSettled {
  const UnixSocketsSettled({required this.clean, required this.leftToOs});

  final int clean;
  final int leftToOs;

  String describe() =>
      'unix sockets at exit: $clean closed cleanly, $leftToOs left to the OS';
}

/// Every unix socket this process holds open, so an exit can close them in
/// order first. One per process; [UnixSocketRegistry.new] is for tests.
class UnixSocketRegistry {
  UnixSocketRegistry({bool? orderly}) : orderly = orderly ?? Platform.isWindows;

  static final UnixSocketRegistry instance = UnixSocketRegistry();

  /// Whether closes here are ordered at all — Windows only: elsewhere a close
  /// leaves nothing pending, and nothing waits.
  final bool orderly;

  final _open = <SettlesOnExit>{};
  final _left = <SettlesOnExit>{};
  final _sinceLastClose = Stopwatch();

  int get openCount => _open.length;

  void add(SettlesOnExit socket) {
    if (orderly) _open.add(socket);
  }

  /// [socket] closed, or was left to the OS ([SocketCloseOutcome.leftToOs]).
  void closed(SettlesOnExit socket, SocketCloseOutcome outcome) {
    if (!_open.remove(socket) && !_left.remove(socket)) return;
    if (outcome == SocketCloseOutcome.leftToOs) {
      _left.add(socket);
    } else {
      _sinceLastClose
        ..reset()
        ..start();
    }
  }

  /// Closes every open socket in order, all at once, each bounded by its
  /// own timeout.
  Future<UnixSocketsSettled> settleAll() async {
    final open = List.of(_open);
    final outcomes = await Future.wait([for (final s in open) s.close()]);
    final left = outcomes.where((o) => o == SocketCloseOutcome.leftToOs);
    // Left earlier and never answered since: still open as the process goes.
    final leftEarlier = _left.where((s) => !open.contains(s)).length;
    return UnixSocketsSettled(
      clean: outcomes.length - left.length,
      leftToOs: left.length + leftEarlier,
    );
  }

  /// Waits until [grace] has passed since the last close: a disconnect issued
  /// after the peer's completes at once, but on the event handler's thread.
  Future<void> afterLastClose(Duration grace) async {
    if (!_sinceLastClose.isRunning) return;
    final wait = grace - _sinceLastClose.elapsed;
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }
}

/// Closes every registered unix socket in order and waits out the grace.
/// Nothing on platforms other than Windows. [log] gets one line.
Future<UnixSocketsSettled?> settleUnixSockets({
  void Function(String line)? log,
  UnixSocketRegistry? registry,
  Duration grace = kSocketSettleGrace,
}) async {
  final sockets = registry ?? UnixSocketRegistry.instance;
  if (!sockets.orderly) return null;
  final settled = await sockets.settleAll();
  await sockets.afterLastClose(grace);
  log?.call(settled.describe());
  return settled;
}

/// The one way a process holding unix sockets exits on purpose: they are
/// closed in order first ([settleUnixSockets]), then [exit].
Future<Never> exitAfterSocketsSettle(
  int code, {
  void Function(String line)? log,
}) async {
  try {
    await settleUnixSockets(log: log);
  } on Object {
    // Exiting is not negotiable; a settle that failed has nothing left to do.
  }
  exit(code);
}

/// A connected unix socket whose close is ordered on Windows ([closeInOrder])
/// and registered for [exitAfterSocketsSettle]. Elsewhere every member is the
/// plain socket's, unchanged.
///
/// On Windows it reads the socket itself, so the peer's end-of-file is seen
/// even after the reader has cancelled, and it closes once that arrives:
/// every receiving side closes promptly, which is what lets the side that
/// went first close with nothing to wait for.
class OrderlySocket implements SettlesOnExit {
  OrderlySocket(this._socket, {UnixSocketRegistry? registry})
    : _registry = registry ?? UnixSocketRegistry.instance {
    if (!orderly) return;
    _registry.add(this);
    _controller = StreamController<Uint8List>(
      // Not before: an unread socket keeps the kernel's backpressure.
      onListen: _read,
      onPause: () {
        if (!_draining) _reading?.pause();
      },
      onResume: () => _reading?.resume(),
      // Read on, unseen, so the end-of-file still arrives.
      onCancel: _drain,
    );
  }

  final Socket _socket;
  final UnixSocketRegistry _registry;
  bool get orderly => _registry.orderly;

  StreamController<Uint8List>? _controller;
  StreamSubscription<Uint8List>? _reading;
  var _draining = false;
  final _peerEnd = Completer<void>();
  Future<void>? _flushing;
  Future<SocketCloseOutcome>? _closing;

  /// The bytes the peer sends; single-subscription, like the socket's own.
  Stream<Uint8List> get stream => _controller?.stream ?? _socket;

  void _read() {
    _reading ??= _socket.listen(
      (chunk) {
        // Buffered while the reader is paused; dropped once it has cancelled.
        final controller = _controller!;
        if (!controller.isClosed) controller.add(chunk);
      },
      onError: (Object error, StackTrace stack) {
        final controller = _controller!;
        if (!controller.isClosed && controller.hasListener) {
          controller.addError(error, stack);
        }
        _peerWent();
      },
      onDone: _peerWent,
    );
  }

  /// Reads to the end whatever the reader does, so a close sees the peer go.
  void _drain() {
    _draining = true;
    _read();
    while (_reading?.isPaused ?? false) {
      _reading?.resume();
    }
  }

  /// Dropped once a close has begun on Windows: the peer has been told this
  /// side is done.
  void add(List<int> bytes) {
    if (_closing != null && orderly) return;
    _socket.add(bytes);
  }

  Future<void> flush() {
    if (!orderly) return _socket.flush();
    final flushing = _socket.flush();
    _flushing = flushing;
    return flushing.whenComplete(() {
      if (identical(_flushing, flushing)) _flushing = null;
    });
  }

  Future<void> get done => _socket.done;

  /// Half-closes the send direction ([Socket.close]); the socket stays open
  /// for reading.
  Future<void> shutdownSend() => _socket.close();

  /// Closes the socket: in order on Windows, and once however often asked.
  @override
  Future<SocketCloseOutcome> close() => _closing ??= _close();

  /// What `Socket.destroy` was: on Windows the same ordered [close], unwaited.
  void destroy() {
    if (!orderly) {
      _socket.destroy();
      return;
    }
    unawaited(close());
  }

  /// [destroy], but waiting for the ordered close on Windows — for a caller
  /// that may exit, or be killed, as soon as this returns.
  Future<void> release() async {
    if (!orderly) {
      _socket.destroy();
      return;
    }
    await close();
  }

  Future<SocketCloseOutcome> _close() async {
    if (!orderly) {
      try {
        await _socket.close();
      } on SocketException {
        // The peer hung up first; there is nothing left to close politely.
      }
      _socket.destroy();
      return SocketCloseOutcome.immediate;
    }
    _drain();
    final outcome = await closeInOrder(_SocketEnd(this));
    _registry.closed(this, outcome);
    return outcome;
  }

  void _peerWent() {
    if (!_peerEnd.isCompleted) _peerEnd.complete();
    final controller = _controller;
    if (controller != null && !controller.isClosed) {
      unawaited(controller.close());
    }
    // After the reader has heard the end, so its own close finds it begun.
    Timer.run(() => unawaited(close()));
  }

  void _destroyNow() {
    // Closing the sink too, so `done` completes as it did when every caller
    // closed before destroying; the read side is over, so it is a full close.
    try {
      unawaited(_socket.close().catchError((Object _) => _socket));
    } on StateError {
      // A flush is in flight; the destroy below ends it.
    }
    _socket.destroy();
    _registry.closed(this, SocketCloseOutcome.clean);
  }
}

class _SocketEnd implements OrderlyEnd {
  _SocketEnd(this._owner);

  final OrderlySocket _owner;

  @override
  bool get peerEnded => _owner._peerEnd.isCompleted;

  @override
  Future<void> get peerEnd => _owner._peerEnd.future;

  @override
  Future<void> shutdownSend() async {
    try {
      await _owner._flushing;
    } on Object {
      // A flush that failed leaves the half-close to fail or not on its own.
    }
    await _owner.shutdownSend();
  }

  @override
  void destroy() => _owner._destroyNow();
}
