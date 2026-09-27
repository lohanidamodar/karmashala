/// The one malformed-JSON exception this package's values throw — a
/// [FormatException], so a transport that refuses those refuses these too.
class AttentionFormatException extends FormatException {
  const AttentionFormatException(super.message);
}

/// [json] as an object, or [AttentionFormatException] naming [what].
Map<String, Object?> attentionObject(Object? json, String what) {
  if (json is Map<String, Object?>) return json;
  if (json is Map) return json.cast<String, Object?>();
  throw AttentionFormatException('$what is not an object');
}

/// The string at [key], or [AttentionFormatException].
String attentionString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw AttentionFormatException('"$key" is not a string');
}

/// The enum value named at [key] among [values], or [AttentionFormatException].
T attentionEnum<T extends Enum>(
  List<T> values,
  Map<String, Object?> json,
  String key,
) {
  final name = json[key];
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw AttentionFormatException('"$key" names no known value: $name');
}

/// The time at [key], or [AttentionFormatException].
DateTime attentionTime(Map<String, Object?> json, String key) {
  final value = json[key];
  final parsed = value is String ? DateTime.tryParse(value) : null;
  if (parsed == null) throw AttentionFormatException('"$key" is not a time');
  return parsed.toUtc();
}
