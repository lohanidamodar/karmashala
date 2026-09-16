import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';

/// [dateFromIso] runs on every date column of every row of every read, and the
/// polling loops read the session tables about once a second — profiled at 8%
/// of the app's CPU during a terminal flood. It has a hand-written fast path,
/// so what matters is that it still agrees with the general parser.
void main() {
  test('agrees with DateTime.parse across everything we store', () {
    final samples = <DateTime>[
      DateTime.utc(2026, 9, 2, 8, 36, 12, 345, 678),
      DateTime.utc(2026, 1, 1),
      DateTime.utc(1999, 12, 31, 23, 59, 59, 999, 999),
      DateTime.utc(2026, 2, 28, 0, 0, 0, 0, 1),
      DateTime.utc(2024, 2, 29, 12), // a leap day
    ];
    for (final moment in samples) {
      final stored = isoFromDate(moment);
      expect(dateFromIso(stored), moment, reason: stored);
      expect(dateFromIso(stored), DateTime.parse(stored).toUtc(), reason: stored);
    }
  });

  test('round-trips whatever isoFromDate writes, at any second', () {
    for (var i = 0; i < 500; i++) {
      final moment = DateTime.utc(2026, 9, 2, 8, i % 60, i % 60, i % 1000);
      expect(dateFromIso(isoFromDate(moment)), moment);
    }
  });

  test('a shape the fast path does not know falls through', () {
    // Local-offset and second-precision forms are not what `isoFromDate`
    // writes, but a row from another tool could carry them.
    expect(dateFromIso('2026-09-02T08:36:12+05:45').isUtc, isTrue);
    expect(
      dateFromIso('2026-09-02T08:36:12Z'),
      DateTime.utc(2026, 9, 2, 8, 36, 12),
    );
    expect(dateFromIso('2026-09-02 08:36:12Z').isUtc, isTrue);
  });

  test('nonsense still raises, rather than returning a wrong answer', () {
    expect(() => dateFromIso('not-a-date'), throwsFormatException);
    expect(() => dateFromIso('20xx-09-02T08:36:12.000Z'), throwsFormatException);
  });
}
