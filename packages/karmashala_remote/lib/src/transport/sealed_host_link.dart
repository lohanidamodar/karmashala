/// The host protocol carried over a sealed channel (slice 5e): once a desktop
/// client's `host.attach` is answered, every sealed frame either way is a run
/// of host-protocol bytes. Neither end parses them here; the relay still sees
/// only sizes.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../protocol.dart';
import 'sealed_channel.dart';

/// The most plaintext one sealed frame carries: well inside the relay's
/// 1 MiB frame, whatever the host protocol's own frame sizes.
const int kHostLinkChunkBytes = 256 * 1024;

/// How long a server keeps a switched link whose socket dropped, for the
/// client to `link.resume` it (Stage 0 step 16). The owner's choice: Wi-Fi
/// blips, a network switch, a short laptop sleep. After it, today's teardown.
const Duration kHostLinkResumeGrace = Duration(minutes: 2);

/// The retain window's caps: the frames a link keeps after sending them, so
/// a resume can send again what the dropped socket lost. The same bounds as
/// `ReconnectingTransport`'s outbound queue.
const int kHostLinkRetainFrames = 256;
const int kHostLinkRetainBytes = 4 * 1024 * 1024;

/// The most resume frames one side may still have unconfirmed — each resume
/// that did not land adds one. More means the link is thrashing: give up.
const int kHostLinkMaxResumeFrames = 16;

/// One end of a host-protocol byte stream inside a [SealedChannel]. Writes
/// are gathered for a turn, sealed in order in chunks of at most
/// [kHostLinkChunkBytes], and handed to [sendSealed]. Frames must arrive in
/// sequence: a gap (a transport that dropped queued frames) or a failure to
/// open ends the link, since a byte stream cannot skip — the client dials
/// again and reattaches from its offsets or the screen.
///
/// **Resume** (Stage 0 step 16). With [retainForResume], every frame sent is
/// also kept in a retain window of at most [kHostLinkRetainFrames] frames and
/// [kHostLinkRetainBytes], oldest dropped first. Each end learns what the
/// other received only at a resume, so the window is a sliding one, not an
/// acked one. While [suspended] nothing is handed to [sendSealed]: frames go
/// to the window only, and one that would push an **unsent** frame out of it
/// ends the link (it could never be resumed).
///
/// A resume frame (`link.resume`, and its answer) is sealed on the same
/// channel, so it takes a sequence out of the byte stream's order. Each end
/// skips the other's resume sequences, and the frames lost before one follow
/// it — [SealedChannel.readmit] opens them past the replay window.
class SealedHostLink {
  SealedHostLink({
    required SealedChannel channel,
    required void Function(Uint8List sealed) sendSealed,
    required int nextReceiveSequence,
    this.deviceId,
    this.deviceName,
    this.capabilities = CapabilitySet.none,
    this.retainForResume = false,
    this.answersPings = false,
  }) : _channel = channel, // ignore: prefer_initializing_formals
       _sendSealed = sendSealed, // ignore: prefer_initializing_formals
       _expected = nextReceiveSequence,
       _firstSend = channel.nextSendSequence;

  final SealedChannel _channel;
  final void Function(Uint8List sealed) _sendSealed;
  int _expected;

  /// The first sequence this link sealed: everything before it was the
  /// envelope exchange that switched the channel, which the peer answered.
  final int _firstSend;

  /// Who is at the other end, on the host's side of a link.
  final String? deviceId;
  final String? deviceName;

  /// On the host's side, what the peer may do; on a desktop's, what the
  /// server's `host.status` granted it for this link.
  final CapabilitySet capabilities;

  /// Whether sent frames are kept for a resume. Off, this is the link it
  /// always was: nothing kept, and nothing can be resumed.
  final bool retainForResume;

  /// Whether an empty frame from the peer — its [ping] — is answered with
  /// one (`link.keepalive`, Stage 0 step 18). The server's end only: the
  /// answer is empty too, and an end that answered both ways would echo for
  /// ever. An empty frame carries no host bytes, so a peer that does not
  /// answer simply ignores it.
  final bool answersPings;

  final _incoming = StreamController<Uint8List>();
  final _done = Completer<void>();
  final _pending = BytesBuilder(copy: false);
  var _flushScheduled = false;
  Future<void> _chain = Future<void>.value();
  String? _closeReason;

  /// Sent (or, while suspended, withheld) frames, oldest first.
  final _retained = ListQueue<({int sequence, Uint8List sealed})>();
  var _retainedBytes = 0;

  /// The newest sequence pushed out of [_retained]; -1 while none was.
  var _evictedThrough = -1;

  var _suspended = false;

  /// The first sequence withheld by the current suspension, or null.
  int? _withheldFrom;

  /// This end's resume frames the peer has not yet been seen to pass.
  final List<int> _sentResumeFrames = <int>[];

  /// The peer's resume frames at or after [_expected]: taken out of order,
  /// so the in-order count steps over them.
  final Set<int> _skipInbound = <int>{};

  /// The peer's host-protocol bytes, in order. Closes with the link.
  Stream<Uint8List> get incoming => _incoming.stream;

  Future<void> get done => _done.future;
  bool get isClosed => _done.isCompleted;
  String? get closeReason => _closeReason;

  /// Whether sending is held for a resume.
  bool get suspended => _suspended;

  /// The last sequence of the peer's taken in order — what a resume reports.
  int get lastReceived => _expected - 1;

  /// What the retain window holds now, in frames and bytes.
  int get retainedFrames => _retained.length;
  int get retainedBytes => _retainedBytes;

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
      _sealPiece(Uint8List.sublistView(bytes, at, end));
    }
  }

  /// Seals an empty frame after everything added so far: proof of life for
  /// an idle link (`link.keepalive`). It takes a sequence and is kept for a
  /// resume like any frame, so the byte stream's order is untouched.
  void ping() {
    if (isClosed) return;
    if (_flushScheduled) _seal();
    _sealPiece(Uint8List(0));
  }

  void _sealPiece(Uint8List piece) {
    _chain = _chain.then((_) async {
      if (isClosed) return;
      // No await between reading the sequence and sealing: they agree.
      final sequence = _channel.nextSendSequence;
      final sealed = await _channel.seal(piece);
      if (isClosed) return;
      if (retainForResume) _retain(sequence, sealed);
      if (isClosed || _suspended) return;
      try {
        _sendSealed(sealed);
      } on Object catch (error) {
        close('the transport refused a frame: $error');
      }
    });
  }

  void _retain(int sequence, Uint8List sealed) {
    if (_suspended) _withheldFrom ??= sequence;
    _retained.add((sequence: sequence, sealed: sealed));
    _retainedBytes += sealed.length;
    while (_retained.length > 1 &&
        (_retained.length > kHostLinkRetainFrames ||
            _retainedBytes > kHostLinkRetainBytes)) {
      final oldest = _retained.removeFirst();
      _retainedBytes -= oldest.sealed.length;
      _evictedThrough = oldest.sequence;
      final withheld = _withheldFrom;
      if (withheld != null && oldest.sequence >= withheld) {
        close('the resume window overflowed while the link was suspended');
        return;
      }
    }
  }

  /// Takes one frame the owner opened. A copy of one already taken is
  /// dropped; anything else out of sequence ends it.
  void receive(SealedFrame opened) {
    if (isClosed) return;
    // A link that moved sockets (Stage 0 step 18) can meet what was in
    // flight on the old one a second time: the copy is not news.
    if (opened.sequence < _expected) return;
    if (opened.sequence != _expected) {
      close('a frame was lost (expected $_expected, got ${opened.sequence})');
      return;
    }
    _expected++;
    _stepOverSkips();
    if (opened.plaintext.isNotEmpty) {
      _incoming.add(Uint8List.fromList(opened.plaintext));
    } else if (answersPings) {
      ping();
    }
  }

  void _stepOverSkips() {
    while (_skipInbound.remove(_expected)) {
      _expected++;
    }
  }

  /// Holds everything sent from here on in the retain window until [resume]
  /// or [close]. Only with [retainForResume].
  void suspend() {
    if (!retainForResume) {
      throw StateError('this link keeps nothing to resume from');
    }
    if (isClosed || _suspended) return;
    _suspended = true;
  }

  /// Why the peer's `link.resume` cannot be taken, or null when it can.
  ///
  /// [peerLastReceived] is the last of this end's sequences the peer took in
  /// order; everything after it must still be in the window. The frame itself
  /// was sealed at [peerResumeSequence], after every host frame the peer sent,
  /// so it may be no further ahead of this end's count than a window.
  String? resumeRefusal({
    required int peerLastReceived,
    required int peerResumeSequence,
  }) {
    if (isClosed) return 'the link is over';
    if (!retainForResume) return 'this link keeps nothing to resume from';
    if (!_suspended) return 'the link is not suspended';
    if (peerLastReceived < _firstSend - 1 ||
        peerLastReceived >= _channel.nextSendSequence) {
      return 'the peer reports a sequence this link never sent';
    }
    if (peerLastReceived < _evictedThrough) {
      return 'what the peer missed is no longer kept';
    }
    final lost = peerResumeSequence - _expected;
    if (lost < 0 || lost > kHostLinkRetainFrames + kHostLinkMaxResumeFrames) {
      return 'the resume frame is out of range';
    }
    if (_sentResumeFrames.length >= kHostLinkMaxResumeFrames) {
      return 'too many resumes in a row';
    }
    return null;
  }

  /// Resumes this suspended link on the peer's `link.resume`, the answering
  /// end's half. On this link's own chain, so no frame interleaves:
  ///
  /// 1. the peer's resume frame and [peerSkip] (its earlier resume frames
  ///    that may not have landed) are stepped over, and the frames it lost
  ///    before [peerResumeSequence] are reopened past the replay window;
  /// 2. [answer] is sealed and sent, given its own sequence, this end's
  ///    [lastReceived] and this end's earlier resume frames the peer must
  ///    step over;
  /// 3. every kept frame after [peerLastReceived] is sent again, as sealed;
  /// 4. sending continues.
  ///
  /// Completes false when the link ended first or the resume is refused.
  Future<bool> resume({
    required int peerLastReceived,
    required int peerResumeSequence,
    Iterable<int> peerSkip = const [],
    required List<int> Function(int sequence, int lastReceived, List<int> skip)
    answer,
  }) {
    final result = Completer<bool>();
    _chain = _chain.then((_) async {
      if (resumeRefusal(
            peerLastReceived: peerLastReceived,
            peerResumeSequence: peerResumeSequence,
          ) !=
          null) {
        result.complete(false);
        return;
      }
      // Inbound: step over the peer's resume frames, reopen what it lost.
      final skips = <int>{
        peerResumeSequence,
        for (final s in peerSkip.take(kHostLinkMaxResumeFrames))
          if (s >= _expected && s < peerResumeSequence) s,
      };
      _skipInbound
        ..removeWhere((s) => s < _expected)
        ..addAll(skips);
      _channel.readmit(_expected, peerResumeSequence, except: _skipInbound);
      _stepOverSkips();
      // Outbound: forget what the peer has, answer, send the rest again.
      while (_retained.isNotEmpty &&
          _retained.first.sequence <= peerLastReceived) {
        _retainedBytes -= _retained.removeFirst().sealed.length;
      }
      _sentResumeFrames.removeWhere((s) => s <= peerLastReceived);
      final sequence = _channel.nextSendSequence;
      final sealed = await _channel.seal(
        answer(sequence, lastReceived, List.unmodifiable(_sentResumeFrames)),
      );
      if (isClosed) {
        result.complete(false);
        return;
      }
      _sentResumeFrames.add(sequence);
      try {
        _sendSealed(sealed);
        for (final frame in _retained.toList()) {
          _sendSealed(frame.sealed);
        }
      } on Object catch (error) {
        // A socket that fails its first frames is no place to resume on, and
        // what went out is unknowable now: the owner's teardown runs.
        result.complete(false);
        close('the transport refused a resumed frame: $error');
        return;
      }
      _suspended = false;
      _withheldFrom = null;
      result.complete(true);
    });
    return result.future;
  }

  /// The resuming end's half, 1 (Stage 0 step 17): seals this end's
  /// `link.resume` on this link's own chain, after every host frame sealed so
  /// far, and counts it among the resume frames the peer must step over.
  /// [frame] is given its sequence, this end's [lastReceived] and this end's
  /// earlier resume frames that may not have landed. Null when the link
  /// ended first or is not suspended — or, with the link closed, when the
  /// peer would have more resume frames to step over than it reads.
  Future<Uint8List?> sealResume(
    List<int> Function(int sequence, int lastReceived, List<int> skip) frame,
  ) {
    final result = Completer<Uint8List?>();
    _chain = _chain.then((_) async {
      if (isClosed || !_suspended || !retainForResume) {
        result.complete(null);
        return;
      }
      // Every resume frame takes a sequence the peer must be told to step
      // over, and the peer reads at most this many: past it, give up.
      if (_sentResumeFrames.length >= kHostLinkMaxResumeFrames - 1) {
        result.complete(null);
        close('too many resumes in a row');
        return;
      }
      final sequence = _channel.nextSendSequence;
      final sealed = await _channel.seal(
        frame(sequence, lastReceived, List.unmodifiable(_sentResumeFrames)),
      );
      if (isClosed) {
        result.complete(null);
        return;
      }
      _sentResumeFrames.add(sequence);
      result.complete(sealed);
    });
    return result.future;
  }

  /// The resuming end's half, 2: the peer answered this end's `link.resume`
  /// at [peerAnswerSequence], having taken this end's frames through
  /// [peerLastReceived]; [peerSkip] lists its earlier answers that may not
  /// have landed. Call it before the next frame is opened, since the frames
  /// the dropped socket lost follow the answer. On this link's own chain:
  ///
  /// 1. the answer and [peerSkip] are stepped over, and the peer's frames
  ///    lost before the answer are reopened past the replay window;
  /// 2. every kept frame after [peerLastReceived] is sent again, as sealed;
  /// 3. sending continues.
  ///
  /// Completes false — and the link is closed — when the answer cannot be
  /// taken: the peer names a sequence this end never sent, or one no longer
  /// kept.
  Future<bool> completeResume({
    required int peerLastReceived,
    required int peerAnswerSequence,
    Iterable<int> peerSkip = const [],
  }) {
    final result = Completer<bool>();
    _chain = _chain.then((_) async {
      String? refusal;
      if (isClosed) {
        refusal = 'the link is over';
      } else if (!_suspended) {
        refusal = 'the link is not suspended';
      } else if (peerLastReceived < _firstSend - 1 ||
          peerLastReceived >= _channel.nextSendSequence) {
        refusal = 'the peer reports a sequence this link never sent';
      } else if (peerLastReceived < _evictedThrough) {
        refusal = 'what the peer missed is no longer kept';
      } else {
        final lost = peerAnswerSequence - _expected;
        if (lost < 0 ||
            lost > kHostLinkRetainFrames + kHostLinkMaxResumeFrames) {
          refusal = 'the resume answer is out of range';
        }
      }
      if (refusal != null) {
        result.complete(false);
        close('the resume could not be taken: $refusal');
        return;
      }
      // Inbound: step over the peer's answers, reopen what it lost.
      final skips = <int>{
        peerAnswerSequence,
        for (final s in peerSkip.take(kHostLinkMaxResumeFrames))
          if (s >= _expected && s < peerAnswerSequence) s,
      };
      _skipInbound
        ..removeWhere((s) => s < _expected)
        ..addAll(skips);
      try {
        _channel.readmit(_expected, peerAnswerSequence, except: _skipInbound);
      } on ArgumentError catch (error) {
        result.complete(false);
        close('the resume could not be taken: $error');
        return;
      }
      _stepOverSkips();
      // Outbound: forget what the peer has, send the rest again.
      while (_retained.isNotEmpty &&
          _retained.first.sequence <= peerLastReceived) {
        _retainedBytes -= _retained.removeFirst().sealed.length;
      }
      _sentResumeFrames.removeWhere((s) => s <= peerLastReceived);
      try {
        for (final frame in _retained.toList()) {
          _sendSealed(frame.sealed);
        }
      } on Object catch (error) {
        result.complete(false);
        close('the transport refused a resumed frame: $error');
        return;
      }
      _suspended = false;
      _withheldFrom = null;
      result.complete(true);
    });
    return result.future;
  }

  /// Ends the link; [reason] is kept for whoever asks why.
  void close([String reason = 'closed']) {
    if (isClosed) return;
    _closeReason = reason;
    _pending.clear();
    _retained.clear();
    _retainedBytes = 0;
    unawaited(_incoming.close());
    _done.complete();
  }
}
