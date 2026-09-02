import '../data/device_stream.dart';

/// How long to wait before each automatic reconnection attempt.
///
/// Bounded on purpose. A live view that silently retries forever is the same
/// failure the watchdog exists to end — the user is told after the last one and
/// given the button instead.
const List<Duration> kStreamReconnectBackoff = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 15),
];

/// What to try next when the live view has stopped showing the truth.
///
/// Ordered by what it costs the user, cheapest first. The owner asked for this
/// directly: "isn't there an automated way to recover it when the user starts
/// interacting, without going through the destructive restart?"
enum StreamRecovery {
  /// Leave it alone: the stream is fine, a step is still being given its
  /// chance, or the ladder has run out and it is the user's turn.
  none,

  /// Ask the device to restart video capture over the control socket. Nothing
  /// is torn down — no process, no forward, no socket, no player — and a fresh
  /// keyframe arrives within a frame or two.
  resetVideo,

  /// Re-open the player on the same stream. The scrcpy server and its sockets
  /// are untouched; only our own muxer and the player are rebuilt.
  reattachPlayer,

  /// Tear the session down and build a new one. Costs a black pane, a port, a
  /// jar push and a few seconds, which is why it is last.
  restart,
}

/// One rung, and how long to wait before taking it.
class StreamRecoveryStep {
  const StreamRecoveryStep(this.action, [this.delay = Duration.zero]);

  static const StreamRecoveryStep none = StreamRecoveryStep(
    StreamRecovery.none,
  );

  final StreamRecovery action;

  /// Only the destructive rung waits: the cheap ones are free, and delaying
  /// them would be visible for no reason.
  final Duration delay;

  @override
  String toString() => 'StreamRecoveryStep($action, $delay)';
}

/// Decides whether a health report is worth recovering from, which rung to try,
/// and how long to wait first.
///
/// Pure, and separate from the pane, because the pane cannot be driven in a
/// widget test — the live view needs a real media_kit `Player`, which needs
/// libmpv — and this is the rule that misbehaved.
///
/// **The escalation is the point.** The counter used to reset on any healthy
/// report at all, and a stream that recovers for a single frame between
/// failures is momentarily healthy every time: on F6IZLV6LMFT4U4ZT that turned
/// five bounded retries into 28 restarts at a flat eleven-second cadence,
/// because every one of them was attempt number one. A failure now only starts
/// the count over when the stream it interrupted had been healthy for
/// [settleAfter] — long enough that this is a new fault rather than the next
/// beat of the same one.
class StreamRestartPolicy {
  StreamRestartPolicy({
    this.backoff = kStreamReconnectBackoff,
    this.settleAfter = const Duration(seconds: 60),
    this.stepGrace = const Duration(seconds: 2),
  });

  final List<Duration> backoff;

  /// How long a stream must have been healthy for its next failure to count as
  /// a fresh incident.
  final Duration settleAfter;

  /// How long a rung is given to work before the next fault is taken as proof
  /// that it did not.
  ///
  /// The watchdog re-reports a fault every second, so without this the ladder
  /// would be climbed in three ticks — and a video reset needs a moment for the
  /// device to encode the keyframe it was asked for.
  final Duration stepGrace;

  int _attempt = 0;
  DateTime? _healthySince;
  DateTime? _lastStepAt;
  bool _triedReset = false;
  bool _triedReattach = false;

  /// How many automatic restarts this incident has already asked for.
  int get attempt => _attempt;

  /// Whether automatic reconnection has given up and it is the user's turn.
  bool get isExhausted => _attempt >= backoff.length;

  /// The rung to take for this report.
  ///
  /// [canResetVideo] is whether a control socket is there to ask down. Without
  /// one the cheapest rung does not exist, and a session that fell back to
  /// `adb shell input` has exactly that problem.
  ///
  /// [StreamRecovery.none] covers everything that must not be touched: a
  /// healthy stream — an idle device included — a rung still being given its
  /// chance, and an incident that has used up its attempts, where trying again
  /// would be the loop rather than a fix.
  StreamRecoveryStep onHealth(
    DeviceStreamHealth health,
    DateTime now, {
    bool canResetVideo = false,
  }) {
    if (!health.needsRestart) {
      _healthySince ??= now;
      return StreamRecoveryStep.none;
    }
    final healthySince = _healthySince;
    if (healthySince != null && now.difference(healthySince) >= settleAfter) {
      _attempt = 0;
      _triedReset = false;
      _triedReattach = false;
    }
    _healthySince = null;

    final lastStep = _lastStepAt;
    if (lastStep != null && now.difference(lastStep) < stepGrace) {
      return StreamRecoveryStep.none;
    }

    // A connection that has ended cannot be repaired from this side: there is
    // nothing left to ask, and nothing downstream to re-attach to.
    if (health.state != DeviceStreamState.ended) {
      if (canResetVideo && !_triedReset) {
        _triedReset = true;
        _lastStepAt = now;
        return const StreamRecoveryStep(StreamRecovery.resetVideo);
      }
      if (!_triedReattach) {
        _triedReattach = true;
        _lastStepAt = now;
        return const StreamRecoveryStep(StreamRecovery.reattachPlayer);
      }
    }

    if (isExhausted) return StreamRecoveryStep.none;
    _lastStepAt = now;
    return StreamRecoveryStep(StreamRecovery.restart, backoff[_attempt++]);
  }

  /// Starts the ladder again. For the restart the user asked for, and for a
  /// move to a different device: neither inherits the last one's failures.
  void reset() {
    _attempt = 0;
    _healthySince = null;
    _lastStepAt = null;
    _triedReset = false;
    _triedReattach = false;
  }
}
