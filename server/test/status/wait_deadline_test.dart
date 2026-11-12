import 'dart:async';

import 'package:karmashala_host/src/status/hosted_session_wait.dart';
import 'package:test/test.dart';

/// A wait's bound: a settled wait keeps no timer for the rest of it.
void main() {
  test('disarming cancels the timer the bound armed', () {
    final timers = <Timer>[];
    late void Function() disarm;
    runZoned(
      () => disarm = armWaitDeadline(null, const Duration(hours: 6), () {}),
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          final timer = parent.createTimer(zone, duration, callback);
          timers.add(timer);
          return timer;
        },
      ),
    );

    expect(timers.single.isActive, isTrue);
    disarm();
    expect(timers.single.isActive, isFalse);
  });

  test('a given deadline still times out, and not once disarmed', () async {
    final first = Completer<void>();
    final second = Completer<void>();
    var timedOut = 0;
    armWaitDeadline((_) => first.future, Duration.zero, () => timedOut++);
    final disarm = armWaitDeadline(
      (_) => second.future,
      Duration.zero,
      () => timedOut += 10,
    );

    disarm();
    first.complete();
    second.complete();
    await Future<void>.delayed(Duration.zero);

    expect(timedOut, 1);
  });
}
