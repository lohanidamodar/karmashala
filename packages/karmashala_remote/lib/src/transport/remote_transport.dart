/// The transport contract the sealed channel sits on. A transport moves opaque
/// frames and knows nothing about the protocol, which is what lets the LAN path
/// and the relay path share one conformance suite.
library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

/// Largest frame a transport will send or accept. Matches the relay's cap.
const int kMaxTransportFrameBytes = 1024 * 1024 + 4096;

/// The most one peer's outbound queue will hold while that peer is away. Four
/// megabytes: an ordinary blip replays in full, and a phone that walked out of
/// range is a bounded amount of the desktop's memory rather than open-ended.
const int kMaxQueuedBytes = 4 * 1024 * 1024;

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
  /// Whole frames, in arrival order, across any internal reconnect. Single-
  /// subscription and buffered, so nothing is lost before the caller listens.
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
/// meet every host at once: one second, doubling, to a thirty-second ceiling.
/// A link that worked, the app returning to the foreground and the user asking
/// all reset it, so the ceiling is never what the user is actually waiting out.
/// "Worked" is a frame from the peer or [kLinkStableAfter] connected — never
/// the connection alone, which a relay grants to anyone.
/// A path with different physics passes its own — see `_localBackoff`.
class Backoff {
  Backoff({
    this.initial = const Duration(seconds: 1),
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

/// How long a connection must hold before its drop is redialled from the
/// first backoff step again. Shorter than any shared relay's lone timeout, so
/// a listener the relay sends away for want of a peer is back in a second;
/// long enough that a relay which takes a socket and hangs up at once is
/// dialled less and less often rather than once a second for ever.
const Duration kLinkStableAfter = Duration(seconds: 30);

/// Length-prefixed framing for a stream transport: `uint32be length || frame`.
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

/// Shared plumbing for a transport that dials, drops and dials again: the frame
/// stream, the state stream, the outbound queue and the backoff, so the LAN and
/// relay clients behave the same way when the network misbehaves.
abstract class ReconnectingTransport implements RemoteTransport {
  ReconnectingTransport({
    Backoff? backoff,
    this.maxQueuedFrames = 256,
    this.maxQueuedBytes = kMaxQueuedBytes,
    this.stableAfter = kLinkStableAfter,
    this.onLog,
  }) : backoff = backoff ?? Backoff();

  /// How long a connection must hold to count as one that worked — see
  /// [kLinkStableAfter].
  final Duration stableAfter;

  /// Frames the caller sent while disconnected. Oldest is dropped on overflow.
  final int maxQueuedFrames;

  /// And the same queue in bytes, which is the bound that actually holds. A
  /// count is not a size: 256 frames at [kMaxTransportFrameBytes] each is a
  /// quarter of a gigabyte held for one phone that walked out of range.
  final int maxQueuedBytes;
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
  int _queuedBytes = 0;

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

  /// What the queue is holding for this peer right now, in bytes.
  int get queuedBytes => _queuedBytes;

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
      // A connection that held was a working one, whether or not the peer
      // ever spoke on it: its drop is news, not the next turn of a loop.
      final held = _connectedFor;
      _connectedFor = null;
      if (held != null && held.elapsed >= stableAfter) backoff.reset();
      if (_closed) break;
      _setState(TransportState.disconnected);
      if (!reconnects) break;
      final wait = backoff.next();
      onLog?.call('reconnecting in ${wait.inMilliseconds}ms');
      await Future<void>.delayed(wait);
    }
    await close();
  }

  /// Running since the current connection came up; null between connections.
  Stopwatch? _connectedFor;

  /// Called by a subclass once its connection is usable.
  ///
  /// The backoff is **not** reset here. A relay upgrades any socket, peer or
  /// no peer, so a connection that opens proves nothing — and resetting on it
  /// made every refusal that arrives after the upgrade (a rendezvous that is
  /// busy, a relay that hangs up at once) a dial a second for as long as the
  /// app stayed open. A frame from the peer resets it, in [onFrame], and so
  /// does a connection that held for [stableAfter], in the loop.
  void onConnected() {
    _connectedFor = Stopwatch()..start();
    _setState(TransportState.connected);
    final queued = List<Uint8List>.of(_queue);
    _queue.clear();
    _queuedBytes = 0;
    for (final frame in queued) {
      if (!writeFrame(frame)) {
        _queue.add(frame);
        _queuedBytes += frame.length;
      }
    }
  }

  /// Drops every frame queued while disconnected, answering how many. For an
  /// owner that keeps its own copies — a suspended host link resends from its
  /// retain window, and a stale flush ahead of the resume answer is a gap.
  int discardQueued() {
    final count = _queue.length;
    _queue.clear();
    _queuedBytes = 0;
    return count;
  }

  /// Called by a subclass for each frame that arrives.
  void onFrame(Uint8List frame) {
    // The peer is there: this link works.
    backoff.reset();
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
    _queue.add(bytes);
    _queuedBytes += bytes.length;
    // Oldest first, until it fits both bounds. The newest frame is never the
    // one dropped: it is the only one the peer has had no chance at.
    var dropped = 0;
    var droppedBytes = 0;
    while (_queue.length > 1 &&
        (_queue.length > maxQueuedFrames || _queuedBytes > maxQueuedBytes)) {
      final oldest = _queue.removeAt(0);
      _queuedBytes -= oldest.length;
      droppedBytes += oldest.length;
      dropped++;
      _dropped++;
    }
    // Said out loud, and counted: a slow reader that is silently paid for is
    // the failure this bound exists to make visible. Never the contents.
    if (dropped > 0) {
      onLog?.call(
        'outbound queue full at $_queuedBytes bytes; dropped $dropped '
        'frame(s), $droppedBytes bytes',
      );
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _queue.clear();
    _queuedBytes = 0;
    await abort();
    _setState(TransportState.closed);
    // Not awaited: a buffered single-subscription controller completes its
    // close only when a listener takes the done event.
    unawaited(_frames.close());
    await _states.close();
  }

  void _setState(TransportState next) {
    if (_state == next || _state == TransportState.closed) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }
}
