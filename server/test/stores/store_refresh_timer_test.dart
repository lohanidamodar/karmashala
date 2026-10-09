import 'dart:async';
import 'dart:math' as math;

import 'package:karmashala_host/src/stores/store_refresh_timer.dart';
import 'package:test/test.dart';

/// The background refresh's timing, over a fake clock and a fake timer that
/// fires only when the test says.
void main() {
  late DateTime now;
  late Duration every;
  late bool connected;
  late bool running;
  late DateTime? lastRead;
  late int refreshes;
  late List<_FakeTimer> timers;
  late StoreRefreshTimer schedule;

  StoreRefreshTimer build({double jitter = 0}) => StoreRefreshTimer(
    every: () => every,
    connected: () => connected,
    running: () => running,
    lastRefreshedAt: () => lastRead,
    refresh: () => refreshes++,
    now: () => now,
    timer: (wait, fire) {
      final timer = _FakeTimer(wait, fire);
      timers.add(timer);
      return timer;
    },
    random: _FixedRandom(jitter),
  );

  _FakeTimer armed() => timers.lastWhere((timer) => timer.isActive);

  setUp(() {
    now = DateTime.utc(2026, 10, 9, 8);
    every = const Duration(hours: 3);
    connected = true;
    running = false;
    lastRead = now;
    refreshes = 0;
    timers = [];
    schedule = build();
  });

  test('the next read is the interval after the last one', () {
    schedule.start();
    expect(armed().wait, const Duration(hours: 3));
    expect(schedule.nextAt, now.add(const Duration(hours: 3)));
    armed().fire();
    expect(refreshes, 1);
  });

  test('a read by hand moves the next one on', () {
    lastRead = now.subtract(const Duration(hours: 2));
    schedule.start();
    expect(armed().wait, const Duration(hours: 1));
    now = now.add(const Duration(minutes: 30));
    lastRead = now;
    schedule.refreshed(answered: true);
    expect(armed().wait, const Duration(hours: 3));
    expect(timers.where((timer) => timer.isActive), hasLength(1));
  });

  test('a store never read is read within a minute', () {
    lastRead = null;
    schedule.start();
    expect(armed().wait, StoreRefreshTimer.shortestWait);
  });

  test('the jitter only ever lengthens the wait, by a tenth at most', () {
    schedule = build(jitter: 0.999)..start();
    final wait = armed().wait;
    expect(wait, greaterThan(const Duration(hours: 3)));
    expect(wait, lessThanOrEqualTo(const Duration(hours: 3, minutes: 18)));
  });

  test('a read due while one runs waits for it, not beside it', () {
    schedule.start();
    running = true;
    armed().fire();
    expect(refreshes, 0);
    expect(armed().wait, StoreRefreshTimer.busyRetry);
    running = false;
    armed().fire();
    expect(refreshes, 1);
  });

  test('reads that reach no store back off, doubling to a day', () {
    schedule.start();
    final waits = <Duration>[];
    for (var i = 0; i < 5; i++) {
      schedule.refreshed(answered: false);
      waits.add(armed().wait);
    }
    expect(waits, const [
      Duration(hours: 6),
      Duration(hours: 12),
      Duration(hours: 24),
      Duration(hours: 24),
      Duration(hours: 24),
    ]);
    schedule.refreshed(answered: true);
    expect(schedule.failures, 0);
    expect(armed().wait, const Duration(hours: 3));
  });

  test('off, or with no store connected, nothing is due', () {
    every = Duration.zero;
    schedule.start();
    expect(timers.where((timer) => timer.isActive), isEmpty);
    expect(schedule.nextAt, isNull);

    every = const Duration(hours: 1);
    connected = false;
    schedule.reschedule();
    expect(timers.where((timer) => timer.isActive), isEmpty);

    connected = true;
    schedule.reschedule();
    expect(armed().wait, const Duration(hours: 1));
    schedule.stop();
    expect(timers.where((timer) => timer.isActive), isEmpty);
  });
}

class _FakeTimer implements Timer {
  _FakeTimer(this.wait, this._fire);

  final Duration wait;
  final void Function() _fire;
  bool _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    _fire();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

class _FixedRandom implements math.Random {
  _FixedRandom(this.value);

  final double value;

  @override
  double nextDouble() => value;

  @override
  bool nextBool() => false;

  @override
  int nextInt(int max) => 0;
}
