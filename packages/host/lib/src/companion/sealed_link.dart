import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala_remote/remote.dart';

/// A transport whose frames are sealed on the way out and opened on the way in.
///
/// `SealedChannel` is a codec — `seal` and `unseal` — not a transport, so
/// something has to hold the two together. The desktop does it inline, where it
/// is tangled with generations, relay listeners and ledgers. A host needs only
/// the composition, and having it as a [RemoteTransport] is what lets
/// `CompanionServer.serve` be the same code sealed or not.
///
/// **A frame that will not open is dropped, not passed on.** Bad sealing,
/// a replay and a sequence jump are all somebody else's frame or somebody's
/// second copy of one; handing any of them up as though the paired phone had
/// sent it is how a link starts answering a stranger.
class SealedLink implements RemoteTransport {
  SealedLink(this._inner, this._channel, {void Function(String message)? onLog})
    : _onLog = onLog {
    _subscription = _inner.frames.listen(_open, onDone: _frames.close);
  }

  final RemoteTransport _inner;
  final SealedChannel _channel;
  final void Function(String message)? _onLog;

  final _frames = StreamController<Uint8List>();
  late final StreamSubscription<Uint8List> _subscription;

  /// Outgoing frames are sealed in order. Sealing is async and `send` is not,
  /// so a queue is what keeps frame two from overtaking frame one.
  Future<void> _outbound = Future<void>.value();

  @override
  Stream<Uint8List> get frames => _frames.stream;

  @override
  void send(List<int> frame) {
    _outbound = _outbound.then((_) async {
      try {
        _inner.send(await _channel.seal(frame));
      } on Object catch (error) {
        _onLog?.call('could not seal a frame: $error');
      }
    });
  }

  Future<void> _open(Uint8List frame) async {
    try {
      final opened = await _channel.unseal(frame);
      if (!_frames.isClosed) _frames.add(opened.plaintext);
    } on SealedChannelException catch (error) {
      // Named rather than swallowed: a replay and a forgery are both refusals,
      // and an operator reading the log needs to know which arrived.
      _onLog?.call('refused a frame: $error');
    }
  }

  @override
  Stream<TransportState> get states => _inner.states;

  @override
  TransportState get state => _inner.state;

  @override
  bool get isConnected => _inner.isConnected;

  @override
  Future<void> close() async {
    await _subscription.cancel();
    if (!_frames.isClosed) await _frames.close();
    await _inner.close();
  }
}
