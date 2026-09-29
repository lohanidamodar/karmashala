/// End-to-end sealing for the remote session API: every application frame is
/// sealed with XChaCha20-Poly1305 under a per-direction key, and the relay sees
/// only its size. Nothing here logs, and a decrypt failure says only that.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'key_schedule.dart';

/// Bytes of nonce on the wire, ahead of the ciphertext.
const int kNonceBytes = 24;

/// Bytes of Poly1305 tag, after the ciphertext.
const int kMacBytes = 16;

/// The 8-byte big-endian sequence that prefixes every sealed plaintext.
const int kSequenceBytes = 8;

/// Fixed overhead a sealed frame adds to its payload.
const int kSealedFrameOverhead = kNonceBytes + kMacBytes + kSequenceBytes;

/// How far back the receiver still accepts an out-of-order frame.
const int kDefaultReplayWindow = 64;

/// Largest jump forward the receiver tolerates. A reconnect loses frames, so a
/// gap is normal; a wild one means the peer or the stream is broken.
const int kDefaultMaxForwardGap = 4096;

/// Which end of the pairing this channel is.
enum ChannelRole {
  host,
  companion;

  /// The direction this end seals with.
  ChannelDirection get sends => this == host
      ? ChannelDirection.hostToDevice
      : ChannelDirection.deviceToHost;

  /// The direction this end opens.
  ChannelDirection get receives => sends.reversed;
}

/// A frame that failed to open. The message never names the frame's contents.
class SealedChannelException implements Exception {
  const SealedChannelException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The frame was cut short, oversized, or its tag did not verify.
class SealedFrameException extends SealedChannelException {
  const SealedFrameException(super.message);
}

/// The frame's sequence was already seen, or is older than the window.
class ReplayedFrameException extends SealedChannelException {
  const ReplayedFrameException(super.message);
}

/// The frame's sequence jumped further ahead than the channel tolerates.
class SequenceGapException extends SealedChannelException {
  const SequenceGapException(super.message);
}

/// A frame that opened cleanly.
class SealedFrame {
  const SealedFrame({required this.sequence, required this.plaintext});

  /// The sender's per-direction frame number.
  final int sequence;
  final Uint8List plaintext;
}

/// One device's sealed channel: seals in one direction, opens the other. Its
/// lifetime is the **rendezvous generation**, not the socket — sequence numbers
/// keep counting across a reconnect, which is what makes a replayed frame from
/// the dropped connection detectable.
class SealedChannel {
  SealedChannel._(
    this._cipher,
    this._sendKey,
    this._receiveKey,
    this.role,
    this._nonceSource, {
    required this.generation,
    required this.replayWindow,
    required this.maxForwardGap,
  });

  /// Builds both directions from the device key derived at pairing. [generation]
  /// is bound into both direction keys, so sequences safely restart at zero when
  /// the rendezvous rotates. [nonceSource] exists so test vectors can pin a
  /// nonce; production callers leave it null.
  static Future<SealedChannel> forDevice({
    required SecretKeyData deviceKey,
    required ChannelRole role,
    int generation = 0,
    int replayWindow = kDefaultReplayWindow,
    int maxForwardGap = kDefaultMaxForwardGap,
    List<int> Function()? nonceSource,
  }) async {
    if (replayWindow < 1) {
      throw ArgumentError.value(replayWindow, 'replayWindow', 'must be >= 1');
    }
    if (maxForwardGap < 1) {
      throw ArgumentError.value(maxForwardGap, 'maxForwardGap', 'must be >= 1');
    }
    final cipher = Xchacha20.poly1305Aead();
    return SealedChannel._(
      cipher,
      await deriveDirectionKey(deviceKey, role.sends, generation: generation),
      await deriveDirectionKey(
        deviceKey,
        role.receives,
        generation: generation,
      ),
      role,
      nonceSource ?? _randomNonce,
      generation: generation,
      replayWindow: replayWindow,
      maxForwardGap: maxForwardGap,
    );
  }

  final Cipher _cipher;
  final SecretKeyData _sendKey;
  final SecretKeyData _receiveKey;
  final ChannelRole role;

  /// The rendezvous counter this channel's keys are bound to.
  final int generation;

  /// How far back an out-of-order frame is still accepted.
  final int replayWindow;

  /// The largest forward jump accepted before the channel calls it broken.
  final int maxForwardGap;

  final List<int> Function() _nonceSource;

  int _nextSend = 0;
  int _highestReceived = -1;
  final Set<int> _received = <int>{};

  /// The sequence the next [seal] will stamp. Callers that carry a protocol
  /// envelope stamp its `seq` from here so the two numbers agree.
  int get nextSendSequence => _nextSend;

  /// The highest sequence opened so far, or -1 before the first frame.
  int get highestReceivedSequence => _highestReceived;

  /// Seals [plaintext] into `nonce || ciphertext || mac`.
  Future<Uint8List> seal(List<int> plaintext) async {
    final sequence = _nextSend++;
    final framed = Uint8List(kSequenceBytes + plaintext.length);
    ByteData.view(framed.buffer).setUint64(0, sequence);
    framed.setRange(kSequenceBytes, framed.length, plaintext);

    final nonce = _nonceSource();
    if (nonce.length != kNonceBytes) {
      throw ArgumentError('nonce must be $kNonceBytes bytes');
    }
    final box = await _cipher.encrypt(
      framed,
      secretKey: _sendKey,
      nonce: nonce,
      aad: role.sends.label.codeUnits,
    );
    return Uint8List.fromList(box.concatenation());
  }

  /// Opens [frame], rejecting a repeat, a frame older than the window, or a
  /// jump further ahead than [maxForwardGap].
  Future<SealedFrame> unseal(List<int> frame) async {
    if (frame.length < kSealedFrameOverhead) {
      throw const SealedFrameException('frame is shorter than its overhead');
    }
    final List<int> opened;
    try {
      opened = await _cipher.decrypt(
        SecretBox.fromConcatenation(
          frame,
          nonceLength: kNonceBytes,
          macLength: kMacBytes,
        ),
        secretKey: _receiveKey,
        aad: role.receives.label.codeUnits,
      );
    } on SecretBoxAuthenticationError {
      throw const SealedFrameException('authentication failed');
    } on ArgumentError {
      throw const SealedFrameException('frame is malformed');
    }

    final bytes = Uint8List.fromList(opened);
    final sequence = ByteData.view(bytes.buffer).getUint64(0);
    _admit(sequence);
    return SealedFrame(
      sequence: sequence,
      plaintext: Uint8List.sublistView(bytes, kSequenceBytes),
    );
  }

  /// Sequences [readmit] reopened: each may be opened once more, even when it
  /// is older than the replay window.
  final Set<int> _readmitted = <int>{};

  /// Lets every sequence in `[from, to)` that is at or below the highest
  /// opened so far be opened **once**, however far behind the replay window
  /// it is — except those in [except].
  ///
  /// For a resumed host link (`link.resume`): the peer's resume frame is
  /// sealed after the frames the dropped socket lost, and those follow it.
  /// The caller vouches that none of them was opened before — a host link
  /// takes its frames strictly in order, so everything from its next expected
  /// sequence on never arrived. Bounded by the caller; [maxForwardGap] caps it
  /// here too.
  void readmit(int from, int to, {Set<int> except = const {}}) {
    if (to - from > maxForwardGap) {
      throw ArgumentError.value(to - from, 'to - from', 'is over the gap cap');
    }
    for (var sequence = from; sequence < to; sequence++) {
      if (sequence < 0 || sequence > _highestReceived) continue;
      if (except.contains(sequence) || _received.contains(sequence)) continue;
      _readmitted.add(sequence);
    }
  }

  /// Lets [sequence], just opened, be opened **once** more: its owner did not
  /// take it, and the peer will send it again (Stage 0 step 18 — a frame
  /// that finished opening on a socket a host link had just left).
  void forget(int sequence) {
    if (sequence < 0 || sequence > _highestReceived) return;
    _received.remove(sequence);
    // Within the window an unseen sequence is admitted anyway; past it, only
    // a readmitted one is.
    if (_highestReceived - sequence >= replayWindow) _readmitted.add(sequence);
  }

  /// Applies the anti-replay policy, or throws.
  void _admit(int sequence) {
    if (sequence <= _highestReceived && _readmitted.remove(sequence)) {
      // Once only: inside the window the ordinary check now catches a second
      // copy; outside it the window already does.
      if (_highestReceived - sequence < replayWindow) _received.add(sequence);
      return;
    }
    if (sequence > _highestReceived) {
      final gap = sequence - _highestReceived - 1;
      if (_highestReceived >= 0 && gap > maxForwardGap) {
        throw SequenceGapException('sequence jumped $gap frames ahead');
      }
      _highestReceived = sequence;
      _received.add(sequence);
      _received.removeWhere((s) => s <= _highestReceived - replayWindow);
      return;
    }
    if (_highestReceived - sequence >= replayWindow) {
      throw const ReplayedFrameException('sequence is older than the window');
    }
    if (!_received.add(sequence)) {
      throw const ReplayedFrameException('sequence already seen');
    }
  }
}

final Random _random = Random.secure();

List<int> _randomNonce() => [
  for (var i = 0; i < kNonceBytes; i++) _random.nextInt(256),
];
