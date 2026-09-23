/// Flow control for the host's pushed frames, by acknowledgement: a slow or
/// absent reader becomes a property of the stream rather than of a relay's
/// eight-frame buffer.
library;

/// Unacked bytes above which unsolicited frames stop.
const int kStreamHighWatermark = 384 * 1024;

/// Unacked bytes below which a paused stream resumes.
const int kStreamLowWatermark = 128 * 1024;

/// Unacked bytes past which the stream fails closed, whatever else is true.
const int kStreamHardLimit = 2 * 1024 * 1024;

/// How long a paused stream may go without ack progress before it fails.
const Duration kStreamStallTimeout = Duration(seconds: 10);

/// The phone acks once this many bytes are unacked, or after
/// [kStreamAckDelay], whichever comes first — never a round trip per frame.
const int kStreamAckBytes = 64 * 1024;
const Duration kStreamAckDelay = Duration(milliseconds: 16);

/// What the host may do with the next unsolicited frame.
enum StreamAdmission {
  send,

  /// Held back: above the high watermark, or failed and waiting for an ack.
  /// The sender re-derives current state later; nothing is queued.
  paused,

  /// Just failed closed. Returned once per failure, so the caller names it to
  /// the phone once.
  failed,
}

/// One sealed link's outbound ledger. Inert until the phone's first ack, so a
/// phone that predates acks is served exactly as before.
class StreamFlow {
  StreamFlow({
    Duration Function()? clock,
    this.highWatermark = kStreamHighWatermark,
    this.lowWatermark = kStreamLowWatermark,
    this.hardLimit = kStreamHardLimit,
    this.stallTimeout = kStreamStallTimeout,
  }) : _clock = clock ?? _monotonic();

  final Duration Function() _clock;
  final int highWatermark;
  final int lowWatermark;
  final int hardLimit;
  final Duration stallTimeout;

  final List<({int seq, int bytes})> _pending = [];
  int _unacked = 0;
  int _highestAcked = -1;
  bool _enabled = false;
  bool _paused = false;
  bool _failed = false;

  /// When the stream last moved: an ack that retired something, or the first
  /// unacked frame after an empty ledger. Stalls are measured from here.
  Duration _progressAt = Duration.zero;

  /// Whether the phone has acked at all on this link.
  bool get enabled => _enabled;
  bool get paused => _paused || _failed;
  bool get failed => _failed;
  int get unackedBytes => _unacked;

  /// Records a frame that went out. Every frame counts — an answer occupies the
  /// pipe as much as news does — but only news is ever held back.
  void sent(int seq, int bytes) {
    if (!_enabled || _failed) return;
    if (_pending.isEmpty) _progressAt = _clock();
    _pending.add((seq: seq, bytes: bytes));
    _unacked += bytes;
  }

  /// The phone rendered everything up to [seq]. Answers true when this ack
  /// reopened a stream that was held back, so the caller can send current
  /// state — never a replay of what was held.
  bool ack(int seq) {
    final wasHeld = paused;
    _enabled = true;
    if (_failed) {
      // The ledger was cleared when it failed; any ack proves a reader again.
      _failed = false;
      _paused = false;
      _highestAcked = seq;
      _progressAt = _clock();
      return wasHeld;
    }
    if (seq <= _highestAcked) return false;
    _highestAcked = seq;
    var retired = false;
    while (_pending.isNotEmpty && _pending.first.seq <= seq) {
      _unacked -= _pending.removeAt(0).bytes;
      retired = true;
    }
    if (retired) _progressAt = _clock();
    if (_paused && _unacked <= lowWatermark) _paused = false;
    return wasHeld && !paused;
  }

  /// Whether an unsolicited frame may go now.
  StreamAdmission admit() {
    if (!_enabled) return StreamAdmission.send;
    if (_failed) return StreamAdmission.paused;
    final stalled = _paused && _clock() - _progressAt > stallTimeout;
    if (_unacked > hardLimit || stalled) {
      _failed = true;
      _paused = false;
      _pending.clear();
      _unacked = 0;
      return StreamAdmission.failed;
    }
    if (_paused) return StreamAdmission.paused;
    if (_unacked >= highWatermark) {
      _paused = true;
      return StreamAdmission.paused;
    }
    return StreamAdmission.send;
  }
}

Duration Function() _monotonic() {
  final watch = Stopwatch()..start();
  return () => watch.elapsed;
}
