import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/activity_by_day.dart';

/// **The by-day lens's bucketing, without a widget.** Days are calendar days
/// in one zone, newest first; within a day, newest first.
void main() {
  // A Monday. UTC throughout, so the test means the same in every zone.
  final today = DateTime.utc(2026, 9, 21, 15, 30);

  List<DayBucket<DateTime>> bucket(List<DateTime> times) =>
      bucketByDay(times, timeOf: (t) => t, today: today);

  test('nothing is no days', () {
    expect(bucket(const []), isEmpty);
  });

  test('groups by calendar day, newest day and newest item first', () {
    final a = DateTime.utc(2026, 9, 21, 9);
    final b = DateTime.utc(2026, 9, 21, 14);
    final c = DateTime.utc(2026, 9, 20, 23, 59);
    final d = DateTime.utc(2026, 9, 18, 8);
    final days = bucket([a, d, c, b]);
    expect(
      [for (final day in days) day.label],
      ['Today', 'Yesterday', 'Friday'],
    );
    expect(days[0].items, [b, a]);
    expect(days[1].items, [c]);
    expect(days[2].items, [d]);
    expect(days[0].day, DateTime.utc(2026, 9, 21));
  });

  test('a minute before midnight and a minute after are two days', () {
    final days = bucket([
      DateTime.utc(2026, 9, 20, 23, 59),
      DateTime.utc(2026, 9, 21, 0, 1),
    ]);
    expect(days, hasLength(2));
    expect(days.first.label, 'Today');
    expect(days.last.label, 'Yesterday');
  });

  test('every item lands in exactly one day', () {
    final times = [
      for (var h = 0; h < 24 * 20; h += 5) today.subtract(Duration(hours: h)),
    ];
    final days = bucket(times);
    expect(days.fold<int>(0, (n, d) => n + d.items.length), times.length);
    for (final day in days) {
      for (final t in day.items) {
        expect(DateTime.utc(t.year, t.month, t.day), day.day);
      }
    }
    final starts = [for (final d in days) d.day];
    expect(starts, [...starts]..sort((a, b) => b.compareTo(a)));
  });

  group('dayLabel', () {
    String label(DateTime day) => dayLabel(day, today: today);

    test('today, yesterday, then the weekday for the rest of the week', () {
      expect(label(DateTime.utc(2026, 9, 21)), 'Today');
      expect(label(DateTime.utc(2026, 9, 20)), 'Yesterday');
      expect(label(DateTime.utc(2026, 9, 19)), 'Saturday');
      expect(label(DateTime.utc(2026, 9, 15)), 'Tuesday');
    });

    test('a week back and further is a date, with the year only when it is '
        'not this one', () {
      expect(label(DateTime.utc(2026, 9, 14)), 'Mon 14 Sep');
      expect(label(DateTime.utc(2026, 1, 2)), 'Fri 2 Jan');
      expect(label(DateTime.utc(2025, 12, 31)), 'Wed 31 Dec 2025');
    });

    test(
      'a day in the future — a skewed clock — is dated, not called today',
      () {
        expect(label(DateTime.utc(2026, 9, 22)), 'Tue 22 Sep');
      },
    );

    test('counts calendar days, so a 23-hour day across a clock change is '
        'still one day back', () {
      // Local times in any zone: the count uses the calendar fields alone.
      final spring = DateTime(2026, 3, 30);
      expect(dayLabel(DateTime(2026, 3, 29), today: spring), 'Yesterday');
      expect(dayLabel(DateTime(2026, 3, 29, 23), today: spring), 'Yesterday');
    });
  });

  test('a tie in time is broken the caller\'s way, so the order is stable', () {
    final at = DateTime.utc(2026, 9, 21, 10);
    final days = bucketByDay(
      ['b', 'a', 'c'],
      timeOf: (_) => at,
      today: today,
      tieBreak: (x, y) => x.compareTo(y),
    );
    expect(days.single.items, ['a', 'b', 'c']);
  });
}
