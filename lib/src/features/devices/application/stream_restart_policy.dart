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

/// Decides whether a health report is worth restarting the live view for, and
/// how long to wait first.
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
  });

  final List<Duration> backoff;

  /// How long a stream must have been healthy for its next failure to count as
  /// a fresh incident.
  final Duration settleAfter;

  int _attempt = 0;
  DateTime? _healthySince;

  /// How many automatic restarts this incident has already asked for.
  int get attempt => _attempt;

  /// Whether automatic reconnection has given up and it is the user's turn.
  bool get isExhausted => _attempt >= backoff.length;

  /// The delay to wait before restarting, or `null` to leave the stream alone.
  ///
  /// `null` covers the two cases that must never restart anything: a healthy
  /// stream — an idle device included — and an incident that has used up its
  /// attempts, where retrying again would be the loop rather than a fix.
  Duration? onHealth(DeviceStreamHealth health, DateTime now) {
    if (!health.needsRestart) {
      _healthySince ??= now;
      return null;
    }
    final healthySince = _healthySince;
    if (healthySince != null && now.difference(healthySince) >= settleAfter) {
      _attempt = 0;
    }
    _healthySince = null;
    if (isExhausted) return null;
    return backoff[_attempt++];
  }

  /// Starts the count again. For the restart the user asked for, and for a
  /// move to a different device: neither inherits the last one's failures.
  void reset() {
    _attempt = 0;
    _healthySince = null;
  }
}
