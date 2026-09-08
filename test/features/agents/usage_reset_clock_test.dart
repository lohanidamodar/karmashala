import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/presentation/usage_chip.dart';

/// **"resets in 2h 14m" says how long, not when.**
///
/// A quota you are waiting on is something people arrange an afternoon around,
/// so the clock time is shown beside the duration rather than instead of it.
///
/// The zone is the whole risk here, and it was invisible before this: the two
/// services hand back reset times differently — an ISO string with a `Z`
/// parses to **UTC**, while Codex's epoch seconds parse to **local**. Nothing
/// noticed while the only use was `difference(now)`, which compares absolute
/// instants either way. Format one without `toLocal()` and it prints the wrong
/// hour, confidently.
void main() {
  test('a UTC reset is shown in local time, not as its UTC hour', () {
    final utc = DateTime.utc(2026, 9, 8, 6, 10);
    final local = utc.toLocal();

    expect(
      formatResetClock(utc, local),
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}',
      reason: 'formatting the UTC hour is the bug this test exists for',
    );
  });

  test('a local reset is shown unchanged', () {
    final now = DateTime(2026, 9, 8, 9, 0);
    expect(formatResetClock(DateTime(2026, 9, 8, 11, 55), now), '11:55');
  });

  test('minutes and hours are zero-padded, so the column does not jitter', () {
    final now = DateTime(2026, 9, 8, 0, 30);
    expect(formatResetClock(DateTime(2026, 9, 8, 9, 5), now), '09:05');
  });

  test('a reset on another day names the day, because a bare clock time '
      'three days out is worse than none', () {
    final now = DateTime(2026, 9, 8, 9, 0); // a Tuesday
    expect(formatResetClock(DateTime(2026, 9, 11, 11, 55), now), 'Fri 11:55');
  });

  test('midnight tonight is tomorrow, and says so', () {
    final now = DateTime(2026, 9, 8, 23, 30);
    expect(formatResetClock(DateTime(2026, 9, 9, 0, 15), now), 'Wed 00:15');
  });

  test('the duration formatter is unchanged — both answers are kept', () {
    expect(formatUsageDuration(const Duration(hours: 2, minutes: 14)), '2h14m');
    expect(formatUsageDuration(Duration.zero), 'now');
  });
}
