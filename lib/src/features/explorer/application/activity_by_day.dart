import 'package:flutter/foundation.dart' show immutable, listEquals;

/// One calendar day's items, newest first.
@immutable
class DayBucket<T> {
  const DayBucket({
    required this.day,
    required this.label,
    required this.items,
  });

  /// Midnight of the day, in the same zone as the times it was built from.
  final DateTime day;

  /// "Today", "Yesterday", a weekday within the week, else a date.
  final String label;

  final List<T> items;

  @override
  bool operator ==(Object other) =>
      other is DayBucket<T> &&
      other.day == day &&
      other.label == label &&
      listEquals(other.items, items);

  @override
  int get hashCode => Object.hash(day, label, Object.hashAll(items));
}

/// [items] grouped by the calendar day of [timeOf], newest day first and
/// newest item first within a day. [timeOf] and [today] must be in one zone —
/// the caller's local time, so "yesterday" is the user's yesterday.
///
/// One pass and one sort: O(n log n) in the items, and nothing reads a clock.
List<DayBucket<T>> bucketByDay<T>(
  Iterable<T> items, {
  required DateTime Function(T item) timeOf,
  required DateTime today,
  int Function(T a, T b)? tieBreak,
}) {
  final timed = [for (final item in items) (item: item, at: timeOf(item))]
    ..sort((a, b) {
      final byTime = b.at.compareTo(a.at);
      if (byTime != 0 || tieBreak == null) return byTime;
      return tieBreak(a.item, b.item);
    });
  final buckets = <DayBucket<T>>[];
  DateTime? current;
  var run = <T>[];
  void close() {
    final day = current;
    if (day == null) return;
    buckets.add(
      DayBucket(
        day: day,
        label: dayLabel(day, today: today),
        items: List.unmodifiable(run),
      ),
    );
  }

  for (final (:item, :at) in timed) {
    final day = _midnight(at);
    if (day != current) {
      close();
      current = day;
      run = <T>[];
    }
    run.add(item);
  }
  close();
  return List.unmodifiable(buckets);
}

/// The heading for [day], seen from [today]. Days are counted on the calendar
/// rather than by elapsed hours, so a daylight-saving change cannot move one.
String dayLabel(DateTime day, {required DateTime today}) {
  final back = _calendarDaysBetween(day, today);
  if (back == 0) return 'Today';
  if (back == 1) return 'Yesterday';
  if (back > 1 && back < 7) return _weekdays[day.weekday - 1];
  final date =
      '${_weekdaysShort[day.weekday - 1]} ${day.day} '
      '${_months[day.month - 1]}';
  return day.year == today.year ? date : '$date ${day.year}';
}

DateTime _midnight(DateTime at) => at.isUtc
    ? DateTime.utc(at.year, at.month, at.day)
    : DateTime(at.year, at.month, at.day);

int _calendarDaysBetween(DateTime from, DateTime to) => DateTime.utc(
  to.year,
  to.month,
  to.day,
).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const _weekdaysShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
