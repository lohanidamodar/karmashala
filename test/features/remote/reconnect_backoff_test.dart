/// The reconnect schedule, written down as the list of delays it produces.
///
/// A list rather than a clock on purpose: the claim is what the sequence *is*,
/// and a test that waits for a delay to elapse proves only that a timer fires.
/// So `jitter` is turned off and the delays are read one after another, which
/// is also the only way to see the difference the ceiling makes.
///
/// The failure behind the change: a floor of 250 ms turned one desktop-side
/// refusal — a relay that is up and answering, with no host at the rendezvous —
/// into four dials and four log lines a second, for as long as an idle app
/// stayed open, to learn the same refusal each time.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/remote/transport/remote_transport.dart';

void main() {
  List<int> delaysOf(Backoff backoff, int count) => [
    for (var i = 0; i < count; i++) backoff.next().inMilliseconds,
  ];

  group('the schedule', () {
    test('doubles from one second to a thirty-second ceiling', () {
      expect(delaysOf(Backoff(jitter: 0), 8), [
        1000,
        2000,
        4000,
        8000,
        16000,
        30000,
        30000,
        30000,
      ]);
    });

    test('a reset puts it back at the first second', () {
      final backoff = Backoff(jitter: 0);
      delaysOf(backoff, 6);
      expect(backoff.attempts, 6);

      backoff.reset();

      expect(backoff.attempts, 0);
      expect(delaysOf(backoff, 3), [1000, 2000, 4000]);
    });

    test('a path with different physics says so, and is not overruled', () {
      // A desktop on the same table is not an internet relay; the local
      // schedule the gateway names for it stays its own.
      final local = Backoff(
        initial: const Duration(milliseconds: 200),
        maximum: const Duration(seconds: 2),
        jitter: 0,
      );

      expect(delaysOf(local, 5), [200, 400, 800, 1600, 2000]);
    });

    test('jitter spreads a delay without leaving the bounds', () {
      // The ceiling is a ceiling, and no delay is ever negative — the two
      // things a randomised schedule can get wrong.
      final backoff = Backoff();
      for (var i = 0; i < 200; i++) {
        final delay = backoff.next();
        expect(delay.isNegative, isFalse);
        expect(delay, lessThanOrEqualTo(const Duration(seconds: 36)));
      }
    });
  });
}
