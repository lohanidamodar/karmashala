/// Conversions between Dart values and their SQLite columns: SQLite has no
/// boolean or date type, so those are `0`/`1` integers and ISO-8601 UTC text.
library;

/// Serializes a [DateTime] to an ISO-8601 string in UTC for storage.
String isoFromDate(DateTime value) => value.toUtc().toIso8601String();

/// Parses a stored ISO-8601 string back into a UTC [DateTime]. Hand-parsed —
/// it was 8% of CPU under a terminal flood — falling back to [DateTime.parse].
DateTime dateFromIso(Object? value) {
  final text = value! as String;
  if (text.length >= 20 &&
      text.codeUnitAt(4) == 0x2D && // '-'
      text.codeUnitAt(10) == 0x54 && // 'T'
      text.codeUnitAt(text.length - 1) == 0x5A) {
    // 'Z'
    try {
      var milliseconds = 0;
      var microseconds = 0;
      if (text.length > 20 && text.codeUnitAt(19) == 0x2E) {
        // '.'
        final fraction = text.substring(20, text.length - 1).padRight(6, '0');
        milliseconds = int.parse(fraction.substring(0, 3));
        microseconds = int.parse(fraction.substring(3, 6));
      }
      return DateTime.utc(
        int.parse(text.substring(0, 4)),
        int.parse(text.substring(5, 7)),
        int.parse(text.substring(8, 10)),
        int.parse(text.substring(11, 13)),
        int.parse(text.substring(14, 16)),
        int.parse(text.substring(17, 19)),
        milliseconds,
        microseconds,
      );
    } on FormatException {
      // Shaped like ours but not actually numeric. The general parser will
      // either read it or raise the error the caller expects.
    }
  }
  return DateTime.parse(text).toUtc();
}

/// Converts a [bool] to its `0`/`1` integer storage form.
int intFromBool(bool value) => value ? 1 : 0;

/// Converts a stored integer (`0`/`1`) back into a [bool].
bool boolFromInt(Object? value) => (value! as int) != 0;
