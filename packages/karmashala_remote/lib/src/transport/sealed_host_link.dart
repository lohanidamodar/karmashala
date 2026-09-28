/// The host protocol carried over a sealed channel (slice 5e): once a desktop
/// client's `host.attach` is answered, every sealed frame either way is a run
/// of host-protocol bytes. Neither end parses them here; the relay still sees
/// only sizes.
library;

import 'dart:async';
import 'dart:typed_data';

import '../protocol.dart';
import 'sealed_channel.dart';

/// The most plaintext one sealed frame carries: well inside the relay's
/// 1 MiB frame, whatever the host protocol's own frame sizes.
const int kHostLinkChunkBytes = 256 * 1024;

/// One end of a host-protocol byte stream inside a [SealedChannel]. Writes
/// are gathered for a turn, sealed in order in chunks of at most
/// [kHostLinkChunkBytes], and handed to [sendSealed]. Frames must arrive in
/// sequence: a gap (a transport that dropped queued frames) or a failure to
/// open ends the link, since a byte stream cannot skip — the client dials
/// again and reattaches from its offsets or the screen.
class SealedHostLink {
  SealedHostLink({
    required SealedChannel channel,
    required void Function(Uint8List sealed) sendSealed,
    required int nextReceiveSequence,
    this.deviceId,
    this.deviceName,
    this.capabilities = CapabilitySet.none,
  }) : _channel = channel, // ignore: prefer_initializing_formals
       _sendSealed = sendSealed, // ignore: prefer_initializing_formals
       _expected = nextReceiveSequence;

  final SealedChannel _channel;
  final void Function(Uint8List sealed) _sendSealed;
  int _expected;

  /// Who is at the other end, on the host's side of a link.
  final String? deviceId;
  final String? deviceName;
  final CapabilitySet capabilities;

  final _incoming = StreamController<Uint8List>();
  final _done = Completer<void>();
  final _pending = BytesBuilder(copy: false);
  var _flushScheduled = false;
  Future<void> _chain = Future<void>.value();
  String? _closeReason;

  /// The peer's host-protocol bytes, in order. Closes with the link.
  Stream<Uint8List> get incoming => _incoming.stream;

  Future<void> get done => _done.future;
  bool get isClosed => _done.isCompleted;
  String? get closeReason => _closeReason;

  /// Queues [bytes]; sealed and sent at the end of this turn.
  void add(Uint8List bytes) {
    if (isClosed) throw StateError('the sealed host link is closed');
    if (bytes.isEmpty) return;
    _pending.add(bytes);
    if (_flushScheduled) return;
    _flushScheduled = true;
    scheduleMicrotask(_seal);
  }

  /// Completes once everything added so far has been sealed and handed on.
  Future<void> flush() {
    if (_flushScheduled) _seal();
    return _chain;
  }

  void _seal() {
    _flushScheduled = false;
    if (_pending.isEmpty || isClosed) return;
    final bytes = _pending.takeBytes();
    for (var at = 0; at < bytes.length; at += kHostLinkChunkBytes) {
      final end = at + kHostLinkChunkBytes < bytes.length
          ? at + kHostLinkChunkBytes
          : bytes.length;
      final piece = Uint8List.sublistView(bytes, at, end);
      _chain = _chain.then((_) async {
        if (isClosed) return;
        final sealed = await _channel.seal(piece);
        if (isClosed) return;
        try {
          _sendSealed(sealed);
        } on Object catch (error) {
          close('the transport refused a frame: $error');
        }
      });
    }
  }

  /// Takes one frame the owner opened. Anything out of sequence ends it.
  void receive(SealedFrame opened) {
    if (isClosed) return;
    if (opened.sequence != _expected) {
      close(
        'a frame was lost (expected $_expected, got ${opened.sequence})',
      );
      return;
    }
    _expected++;
    if (opened.plaintext.isNotEmpty) {
      _incoming.add(Uint8List.fromList(opened.plaintext));
    }
  }

  /// Ends the link; [reason] is kept for whoever asks why.
  void close([String reason = 'closed']) {
    if (isClosed) return;
    _closeReason = reason;
    _pending.clear();
    unawaited(_incoming.close());
    _done.complete();
  }
}
