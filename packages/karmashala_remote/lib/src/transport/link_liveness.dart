/// Liveness for an idle sealed link: a deadline on inbound silence, on a
/// monotonic clock. Any frame from the peer is proof of life.
library;

import 'dart:async';

/// The phone pings after this much inbound silence — about the relay's own
/// 25 s heartbeat, so a cellular radio already awake for that pays for this.
const Duration kLinkPingAfter = Duration(seconds: 25);

/// The phone declares the host gone after this much inbound silence: two
/// unanswered pings plus a full interval of slack for a cellular round trip.
const Duration kLinkDeadAfter = Duration(seconds: 75);

/// The host drops a pinging phone after this much silence. Longer than
/// [kLinkDeadAfter] so the end that can redial notices first.
const Duration kHostLinkDeadAfter = Duration(seconds: 90);

/// How often silence is measured.
const Duration kLinkLivenessTick = Duration(seconds: 5);

/// One link's silence deadline. Inert until [start]. A tick that arrives far
/// later than scheduled means this process was asleep or frozen (laptop lid,
/// Android doze); that gap is not the peer's silence, so it restarts the count.
class LinkLiveness {
  LinkLiveness({
    required this.onDead,
    this.onPing,
    this.pingAfter = kLinkPingAfter,
    this.deadAfter = kLinkDeadAfter,
    this.tick = kLinkLivenessTick,
    Duration Function()? clock,
  }) : _clock = clock ?? _monotonic();

  /// Called once per [start], when [deadAfter] passes with nothing heard.
  final void Function(Duration silence) onDead;

  /// Asks the peer for a frame. Null for an end that only listens.
  final void Function()? onPing;

  final Duration pingAfter;
  final Duration deadAfter;
  final Duration tick;
  final Duration Function() _clock;

  Timer? _timer;
  Duration _heardAt = Duration.zero;
  Duration _pingedAt = Duration.zero;
  Duration _tickedAt = Duration.zero;

  bool get running => _timer != null;

  /// Starts the deadline from now. Idempotent while running.
  void start() {
    if (_timer != null) return;
    final now = _clock();
    _heardAt = now;
    _pingedAt = now;
    _tickedAt = now;
    _timer = Timer.periodic(tick, (_) => _check());
  }

  /// A frame arrived from the peer.
  void heard() => _heardAt = _clock();

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _check() {
    final now = _clock();
    final slept = now - _tickedAt > tick * 3;
    _tickedAt = now;
    if (slept) {
      _heardAt = now;
      _pingedAt = now;
      onPing?.call();
      return;
    }
    final silence = now - _heardAt;
    if (silence >= deadAfter) {
      stop();
      onDead(silence);
      return;
    }
    if (silence >= pingAfter && now - _pingedAt >= pingAfter) {
      _pingedAt = now;
      onPing?.call();
    }
  }
}

Duration Function() _monotonic() {
  final watch = Stopwatch()..start();
  return () => watch.elapsed;
}
