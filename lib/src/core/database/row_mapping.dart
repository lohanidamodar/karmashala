/// Small helpers for converting between Dart values and their SQLite column
/// representations. SQLite has no native boolean or date types, so booleans are
/// stored as `0`/`1` integers and timestamps as ISO-8601 UTC strings.
library;

/// Serializes a [DateTime] to an ISO-8601 string in UTC for storage.
String isoFromDate(DateTime value) => value.toUtc().toIso8601String();

/// Parses a stored ISO-8601 string back into a UTC [DateTime].
DateTime dateFromIso(Object? value) => DateTime.parse(value! as String).toUtc();

/// Converts a [bool] to its `0`/`1` integer storage form.
int intFromBool(bool value) => value ? 1 : 0;

/// Converts a stored integer (`0`/`1`) back into a [bool].
bool boolFromInt(Object? value) => (value! as int) != 0;
