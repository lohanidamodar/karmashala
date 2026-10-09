import 'dart:async';
import 'dart:math' as math;

/// Reads the stores on its own every so often, so a change arrives with no
/// window open. Each wait is lengthened by up to [jitterShare] of itself, so
/// servers started together do not ask the stores together; a refresh that
/// reached no store doubles the next wait, up to [longestWait].
class StoreRefreshTimer {
  StoreRefreshTimer({
    required this.every,
    required this.connected,
    required this.running,
    required this.lastRefreshedAt,
    required this.refresh,
    required this.now,
    Timer Function(Duration wait, void Function() fire)? timer,
    math.Random? random,
    this.log,
  }) : _timer = timer ?? Timer.new,
       _random = random ?? math.Random();

  /// The person's choice; [Duration.zero] is off.
  final Duration Function() every;
  final bool Function() connected;

  /// Whether a refresh is under way, which a due read leaves alone.
  final bool Function() running;

  /// When a read last reached a store.
  final DateTime? Function() lastRefreshedAt;

  /// Starts a refresh; its end is told back with [refreshed].
  final void Function() refresh;
  final DateTime Function() now;
  final void Function(String message)? log;

  final Timer Function(Duration wait, void Function() fire) _timer;
  final math.Random _random;

  static const double jitterShare = 0.1;
  static const Duration longestWait = Duration(hours: 24);
  static const Duration shortestWait = Duration(minutes: 1);

  /// How long a due read waits for one under way to end.
  static const Duration busyRetry = Duration(minutes: 5);

  Timer? _pending;
  DateTime? _nextAt;
  int _failures = 0;
  bool _started = false;

  /// When the next read is due; null while none is.
  DateTime? get nextAt => _nextAt;

  /// Refreshes in a row that reached no store.
  int get failures => _failures;

  void start() {
    _started = true;
    reschedule();
  }

  void stop() {
    _started = false;
    _cancel();
  }

  /// A refresh ended, by this timer or by hand: [answered] when a store
  /// answered it.
  void refreshed({required bool answered}) {
    _failures = answered ? 0 : _failures + 1;
    reschedule();
  }

  /// The wait before the next read, at [failures] failures in a row, before
  /// jitter.
  Duration baseWait() {
    final every = this.every();
    var wait = every * math.pow(2, math.min(_failures, 16)).toInt();
    final cap = every > longestWait ? every : longestWait;
    if (wait > cap) wait = cap;
    return wait;
  }

  /// Sets the next read from now, the choice and the last read.
  void reschedule() {
    _cancel();
    final every = this.every();
    if (!_started || every <= Duration.zero || !connected()) return;
    final at = now();
    final base = baseWait();
    // After a failure the wait runs from now; otherwise from the last read,
    // so one asked by hand moves the next one on.
    final from = _failures > 0 ? at : (lastRefreshedAt() ?? at.subtract(base));
    final jitter = base * (_random.nextDouble() * jitterShare);
    var wait = from.add(base).add(jitter).difference(at);
    if (wait < shortestWait) wait = shortestWait;
    _arm(wait);
  }

  void _arm(Duration wait) {
    _cancel();
    _nextAt = now().add(wait);
    _pending = _timer(wait, _fire);
  }

  void _fire() {
    _pending = null;
    _nextAt = null;
    if (!_started) return;
    if (running()) {
      _arm(busyRetry);
      return;
    }
    log?.call('stores: a background read is due');
    refresh();
  }

  void _cancel() {
    _pending?.cancel();
    _pending = null;
    _nextAt = null;
  }
}
