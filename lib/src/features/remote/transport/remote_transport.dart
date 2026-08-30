/// The transport contract the sealed channel sits on.
///
/// A transport moves opaque frames. It knows nothing about the protocol, and
/// the protocol knows nothing about which transport carried it — that is what
/// lets the LAN path and the relay path share one conformance suite.
library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

/// Largest frame a transport will send or accept. Matches the relay's cap.
const int kMaxTransportFrameBytes = 1024 * 1024 + 4096;

/// Bytes of big-endian length prefix on a stream transport.
const int kFrameHeaderBytes = 4;

/// Where a transport is in its connect/reconnect cycle.
enum TransportState {
  /// Not started yet.
  idle,

  /// Dialling, or waiting out a backoff before dialling again.
  connecting,

  /// Frames can flow.
  connected,

  /// The link dropped; a reconnect is scheduled unless the transport is closed.
  disconnected,

  /// Closed by the caller. Terminal.
  closed,
}

/// A framed, connection-oriented byte pipe between the host and one phone.
abstract class RemoteTransport {
  /// Whole frames, in arrival order, across any internal reconnect.
  ///
  /// Single-subscription and buffered, so nothing is lost between the first
  /// connection and the caller listening.
  Stream<Uint8List> get frames;

  /// State changes, starting from the current state.
  Stream<TransportState> get states;

  TransportState get state;

  bool get isConnected => state == TransportState.connected;

  /// Queues [frame] for the peer. Frames sent while disconnected wait in a
  /// bounded queue and go out on the next connection.
  void send(List<int> frame);

  /// Closes for good. A closed transport never reconnects.
  Future<void> close();
}

/// A transport gave up, or was handed something it cannot carry.
class TransportException implements Exception {
  const TransportException(this.message);

  final String message;

  @override
  String toString() => 'TransportException: $message';
}

/// The peer's framing was wrong — a length that cannot be right, most likely a
/// peer speaking some other protocol.
class TransportFramingException extends TransportException {
  const TransportFramingException(super.message);
}

/// Capped exponential backoff with jitter, so a relay coming back up does not
/// meet every host at once.
class Backoff {
  Backoff({
    this.initial = const Duration(milliseconds: 250),
    this.maximum = const Duration(seconds: 30),
    this.multiplier = 2.0,
    this.jitter = 0.2,
    Random? random,
  }) : _random = random ?? Random();

  final Duration initial;
  final Duration maximum;
  final double multiplier;

  /// Fraction of the delay that is randomised, either way.
  final double jitter;

  final Random _random;

  int _attempts = 0;

  int get attempts => _attempts;

  /// The delay before the next attempt, growing until it reaches [maximum].
  Duration next() {
    final growth = initial.inMicroseconds * pow(multiplier, _attempts);
    final capped = min(growth, maximum.inMicroseconds.toDouble());
    _attempts++;
    final spread = capped * jitter * (_random.nextDouble() * 2 - 1);
    return Duration(microseconds: max(0, (capped + spread).round()));
  }

  void reset() => _attempts = 0;
}

/// Length-prefixed framing for a stream transport: `uint32be length || frame`.
///
/// WebSocket already has message boundaries, so only the LAN path needs this.
class LengthPrefixedFramer {
  LengthPrefixedFramer({this.maxFrameBytes = kMaxTransportFrameBytes});

  final int maxFrameBytes;

  Uint8List _buffer = Uint8List(0);
  int _start = 0;

  /// Wraps [frame] with its length prefix.
  static Uint8List encode(List<int> frame) {
    final out = Uint8List(kFrameHeaderBytes + frame.length);
    ByteData.view(out.buffer).setUint32(0, frame.length);
    out.setRange(kFrameHeaderBytes, out.length, frame);
    return out;
  }

  /// Feeds [chunk] in and returns whatever whole frames it completed.
  List<Uint8List> add(List<int> chunk) {
    _append(chunk);
    final frames = <Uint8List>[];
    while (true) {
      final available = _buffer.length - _start;
      if (available < kFrameHeaderBytes) break;
      final length = ByteData.view(
        _buffer.buffer,
        _buffer.offsetInBytes + _start,
        kFrameHeaderBytes,
      ).getUint32(0);
      if (length > maxFrameBytes) {
        throw TransportFramingException(
          'peer announced a $length byte frame, over the $maxFrameBytes cap',
        );
      }
      if (available < kFrameHeaderBytes + length) break;
      frames.add(
        Uint8List.fromList(
          Uint8List.sublistView(
            _buffer,
            _start + kFrameHeaderBytes,
            _start + kFrameHeaderBytes + length,
          ),
        ),
      );
      _start += kFrameHeaderBytes + length;
    }
    _compact();
    return frames;
  }

  void _append(List<int> chunk) {
    final keep = _buffer.length - _start;
    final grown = Uint8List(keep + chunk.length)
      ..setRange(0, keep, _buffer, _start)
      ..setRange(keep, keep + chunk.length, chunk);
    _buffer = grown;
    _start = 0;
  }

  void _compact() {
    if (_start == 0) return;
    _buffer = Uint8List.fromList(Uint8List.sublistView(_buffer, _start));
    _start = 0;
  }
}

/// Shared plumbing for a transport that dials, drops and dials again.
///
/// Subclasses implement one connection attempt; this owns the frame stream, the
/// state stream, the outbound queue and the backoff, so the LAN and relay
/// clients behave the same way when the network misbehaves.
abstract class ReconnectingTransport implements RemoteTransport {
  ReconnectingTransport({
    Backoff? backoff,
    this.maxQueuedFrames = 256,
    this.onLog,
  }) : backoff = backoff ?? Backoff();

  /// Frames the caller sent while disconnected. Oldest is dropped on overflow.
  final int maxQueuedFrames;
  final Backoff backoff;

  /// Lifecycle only. Never called with frame contents.
  final void Function(String message)? onLog;

  /// Deliberately single-subscription: it buffers until the caller listens, so
  /// a frame that arrives between connecting and subscribing is not lost.
  final StreamController<Uint8List> _frames = StreamController<Uint8List>();
  final StreamController<TransportState> _states =
      StreamController<TransportState>.broadcast();
  final List<Uint8List> _queue = <Uint8List>[];

  TransportState _state = TransportState.idle;
  bool _closed = false;
  int _dropped = 0;

  @override
  Stream<Uint8List> get frames => _frames.stream;

  @override
  Stream<TransportState> get states async* {
    yield _state;
    yield* _states.stream;
  }

  @override
  TransportState get state => _state;

  @override
  bool get isConnected => _state == TransportState.connected;

  /// Frames dropped because the queue was full while disconnected.
  int get droppedFrames => _dropped;

  /// Opens one connection and returns when it has ended. Throws to signal a
  /// failed attempt; the loop then waits out the backoff and tries again.
  Future<void> connectOnce();

  /// Hands the current connection a frame, or returns false when there is none.
  bool writeFrame(Uint8List frame);

  /// Aborts the connection in flight, if any.
  Future<void> abort();

  /// Whether a dropped connection should be dialled again. False for a link
  /// the listener accepted: there the peer redials and gets a new link.
  bool get reconnects => true;

  /// Starts the connect/reconnect loop. Safe to call once.
  void start() {
    if (_state != TransportState.idle) return;
    unawaited(_loop());
  }

  Future<void> _loop() async {
    while (!_closed) {
      _setState(TransportState.connecting);
      try {
        await connectOnce();
      } on Object catch (error) {
        onLog?.call('connection attempt failed: $error');
      }
      if (_closed) break;
      _setState(TransportState.disconnected);
      if (!reconnects) break;
      final wait = backoff.next();
      onLog?.call('reconnecting in ${wait.inMilliseconds}ms');
      await Future<void>.delayed(wait);
    }
    await close();
  }

  /// Called by a subclass once its connection is usable.
  void onConnected() {
    backoff.reset();
    _setState(TransportState.connected);
    final queued = List<Uint8List>.of(_queue);
    _queue.clear();
    for (final frame in queued) {
      if (!writeFrame(frame)) {
        _queue.add(frame);
      }
    }
  }

  /// Called by a subclass for each frame that arrives.
  void onFrame(Uint8List frame) {
    if (!_frames.isClosed) _frames.add(frame);
  }

  @override
  void send(List<int> frame) {
    if (_closed) throw const TransportException('transport is closed');
    if (frame.length > kMaxTransportFrameBytes) {
      throw TransportException(
        'frame of ${frame.length} bytes is over the '
        '$kMaxTransportFrameBytes cap',
      );
    }
    final bytes = Uint8List.fromList(frame);
    if (_state == TransportState.connected && writeFrame(bytes)) return;
    if (_queue.length >= maxQueuedFrames) {
      _queue.removeAt(0);
      _dropped++;
      onLog?.call('outbound queue full, dropped the oldest frame');
    }
    _queue.add(bytes);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _queue.clear();
    await abort();
    _setState(TransportState.closed);
    // Not awaited: a buffered single-subscription controller only completes its
    // close when a listener takes the done event, and a caller that never read
    // the frames would hang here forever.
    unawaited(_frames.close());
    await _states.close();
  }

  void _setState(TransportState next) {
    if (_state == next || _state == TransportState.closed) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }
}
