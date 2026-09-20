/// A five-field cron expression: `*`, a number, `a-b`, `/step`, `,` lists and
/// nothing else — refused, not half-parsed. Matched in local time, like cron(8).
library;

/// One parsed field: which values of its range match.
class _CronField {
  const _CronField(this.allowed, {required this.isUnrestricted});

  final Set<int> allowed;

  /// True when the field was written as a bare `*` — how it was written, not
  /// what it covers: `0-6` is a restriction even though it matches every day.
  final bool isUnrestricted;

  bool matches(int value) => allowed.contains(value);

  static _CronField? parse(String raw, int min, int max, {int? wrap}) {
    final allowed = <int>{};
    var unrestricted = false;
    for (final part in raw.split(',')) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) return null;
      var body = trimmed;
      var step = 1;
      final slash = body.indexOf('/');
      if (slash >= 0) {
        final stepText = body.substring(slash + 1);
        body = body.substring(0, slash);
        final parsed = int.tryParse(stepText);
        if (parsed == null || parsed < 1) return null;
        step = parsed;
      }
      int from;
      int to;
      if (body == '*') {
        from = min;
        to = max;
        if (step == 1) unrestricted = true;
      } else if (body.contains('-')) {
        final ends = body.split('-');
        if (ends.length != 2) return null;
        final low = int.tryParse(ends[0].trim());
        final high = int.tryParse(ends[1].trim());
        if (low == null || high == null || low > high) return null;
        from = low;
        to = high;
      } else {
        final value = int.tryParse(body);
        if (value == null) return null;
        from = value;
        to = slash >= 0 ? max : value;
      }
      if (from < min || to > max) return null;
      for (var value = from; value <= to; value += step) {
        allowed.add(wrap != null && value == wrap ? min : value);
      }
    }
    if (allowed.isEmpty) return null;
    return _CronField(allowed, isUnrestricted: unrestricted);
  }
}

class CronSchedule {
  const CronSchedule._(
    this.expression,
    this._minute,
    this._hour,
    this._dayOfMonth,
    this._month,
    this._dayOfWeek,
  );

  /// The text as the user wrote it.
  final String expression;

  final _CronField _minute;
  final _CronField _hour;
  final _CronField _dayOfMonth;
  final _CronField _month;
  final _CronField _dayOfWeek;

  /// Parses `minute hour day-of-month month day-of-week`, or **null**. Sunday
  /// is `0` and `7` alike, the one dialect difference every cron shares.
  static CronSchedule? parse(String expression) {
    final fields = expression.trim().split(RegExp(r'\s+'));
    if (fields.length != 5) return null;
    final minute = _CronField.parse(fields[0], 0, 59);
    final hour = _CronField.parse(fields[1], 0, 23);
    final dayOfMonth = _CronField.parse(fields[2], 1, 31);
    final month = _CronField.parse(fields[3], 1, 12);
    final dayOfWeek = _CronField.parse(fields[4], 0, 7, wrap: 7);
    if (minute == null ||
        hour == null ||
        dayOfMonth == null ||
        month == null ||
        dayOfWeek == null) {
      return null;
    }
    return CronSchedule._(
      expression.trim(),
      minute,
      hour,
      dayOfMonth,
      month,
      dayOfWeek,
    );
  }

  /// Whether the day of [at] fires. The OR rule: with both day fields
  /// restricted either match counts; with one, only it decides.
  bool _dayMatches(DateTime at) {
    // `DateTime.weekday` is 1..7 with Monday first; cron is 0..6 with Sunday.
    final weekday = at.weekday == DateTime.sunday ? 0 : at.weekday;
    final domRestricted = !_dayOfMonth.isUnrestricted;
    final dowRestricted = !_dayOfWeek.isUnrestricted;
    if (domRestricted && dowRestricted) {
      return _dayOfMonth.matches(at.day) || _dayOfWeek.matches(weekday);
    }
    if (domRestricted) return _dayOfMonth.matches(at.day);
    if (dowRestricted) return _dayOfWeek.matches(weekday);
    return true;
  }

  /// How far ahead or behind a search gives up. Five years covers a leap-day
  /// `0 0 29 2 *` and bounds a combination that can never occur.
  static const _searchDays = 366 * 5;

  /// The first occurrence strictly after [after], or null within the bound.
  /// Returned in the zone it was asked in; matched in local time.
  DateTime? nextAfter(DateTime after) {
    final wasUtc = after.isUtc;
    var at = _truncate(after.toLocal()).add(const Duration(minutes: 1));
    final limit = at.add(const Duration(days: _searchDays));
    while (at.isBefore(limit)) {
      if (!_month.matches(at.month)) {
        at = _startOfNextMonth(at);
        continue;
      }
      if (!_dayMatches(at)) {
        at = _startOfNextDay(at);
        continue;
      }
      if (!_hour.matches(at.hour)) {
        at = _startOfNextHour(at);
        continue;
      }
      if (_minute.matches(at.minute)) return wasUtc ? at.toUtc() : at;
      at = at.add(const Duration(minutes: 1));
    }
    return null;
  }

  /// The last occurrence at or before [at], or null within the bound. Its own
  /// walk, so the newest miss stays findable when the count is capped.
  DateTime? previousAtOrBefore(DateTime at) {
    final wasUtc = at.isUtc;
    var cursor = _truncate(at.toLocal());
    final limit = cursor.subtract(const Duration(days: _searchDays));
    while (cursor.isAfter(limit)) {
      if (!_month.matches(cursor.month)) {
        cursor = _endOfPreviousMonth(cursor);
        continue;
      }
      if (!_dayMatches(cursor)) {
        cursor = _endOfPreviousDay(cursor);
        continue;
      }
      if (!_hour.matches(cursor.hour)) {
        cursor = _endOfPreviousHour(cursor);
        continue;
      }
      if (_minute.matches(cursor.minute)) {
        return wasUtc ? cursor.toUtc() : cursor;
      }
      cursor = cursor.subtract(const Duration(minutes: 1));
    }
    return null;
  }

  /// Occurrences strictly after [since] and at or before [now], ascending,
  /// stopping at [limit] so a fortnight of a minutely schedule is bounded.
  List<DateTime> occurrencesBetween(
    DateTime since,
    DateTime now, {
    int limit = 500,
  }) {
    if (!since.isBefore(now)) return const [];
    final out = <DateTime>[];
    var cursor = since;
    while (out.length < limit) {
      final next = nextAfter(cursor);
      if (next == null || next.isAfter(now)) break;
      out.add(next);
      cursor = next;
    }
    return out;
  }

  static DateTime _truncate(DateTime at) =>
      DateTime(at.year, at.month, at.day, at.hour, at.minute);

  static DateTime _startOfNextMonth(DateTime at) =>
      DateTime(at.year, at.month + 1);

  static DateTime _startOfNextDay(DateTime at) =>
      DateTime(at.year, at.month, at.day + 1);

  static DateTime _startOfNextHour(DateTime at) =>
      DateTime(at.year, at.month, at.day, at.hour + 1);

  static DateTime _endOfPreviousMonth(DateTime at) =>
      DateTime(at.year, at.month, 0, 23, 59);

  static DateTime _endOfPreviousDay(DateTime at) =>
      DateTime(at.year, at.month, at.day - 1, 23, 59);

  static DateTime _endOfPreviousHour(DateTime at) =>
      DateTime(at.year, at.month, at.day, at.hour - 1, 59);

  @override
  String toString() => 'CronSchedule("$expression")';
}

/// Why [expression] will not do as a schedule, or `null` when it will — the
/// words the arm form shows and the words the write path throws, from one place.
String? cronRefusal(String expression) {
  final trimmed = expression.trim();
  if (trimmed.isEmpty) {
    return 'A recurring automation needs a schedule. Five fields: minute, '
        'hour, day of month, month, day of week — "0 3 * * *" is 03:00 every '
        'day.';
  }
  final schedule = CronSchedule.parse(trimmed);
  if (schedule == null) {
    return '"$trimmed" is not a five-field cron expression Karmashala can '
        'read. It understands "*", a number, "a-b", a "/step" and "," lists, '
        'and nothing else — no "@daily", no "L", no seconds field. It is '
        'refused rather than guessed at, because an expression that half '
        'parsed would fire at times nobody asked for.';
  }
  if (schedule.nextAfter(DateTime.now()) == null) {
    return '"$trimmed" parses but never comes round — nothing matches it in '
        'the next five years.';
  }
  return null;
}
