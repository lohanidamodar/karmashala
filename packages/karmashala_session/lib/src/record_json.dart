import 'package:agent_cli/process.dart';

/// The small readers every session value's JSON shares. Each throws
/// [FormatException] on a value out of shape, which a client reads as a
/// server of another build.

String jsonString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw FormatException('"$key" must be a string');
}

String? jsonOptionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null || value is String) return value as String?;
  throw FormatException('"$key" must be a string or absent');
}

int jsonInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int) return value;
  throw FormatException('"$key" must be a whole number');
}

int? jsonOptionalInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null || value is int) return value as int?;
  throw FormatException('"$key" must be a whole number or absent');
}

bool jsonBool(Map<String, Object?> json, String key) {
  final value = json[key] ?? false;
  if (value is bool) return value;
  throw FormatException('"$key" must be true or false');
}

String jsonDate(DateTime at) => at.toUtc().toIso8601String();

DateTime jsonDateOf(Map<String, Object?> json, String key) =>
    DateTime.parse(jsonString(json, key)).toUtc();

DateTime? jsonOptionalDateOf(Map<String, Object?> json, String key) {
  final value = jsonOptionalString(json, key);
  return value == null ? null : DateTime.parse(value).toUtc();
}

Map<String, Object?> jsonPath(EnvironmentPath path) => {
  'environmentId': path.environmentId,
  'path': path.path,
};

EnvironmentPath? jsonOptionalPathOf(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is Map &&
      value['environmentId'] is String &&
      value['path'] is String) {
    return EnvironmentPath(
      environmentId: value['environmentId'] as String,
      path: value['path'] as String,
    );
  }
  throw FormatException('"$key" must be a path in an environment');
}

/// The value named [name] among [values], or [fallback] for a word this build
/// does not know — a newer server's.
T jsonEnum<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return fallback;
}
