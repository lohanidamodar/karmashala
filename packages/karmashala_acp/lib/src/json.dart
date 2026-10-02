/// A decoded JSON object, as `dart:convert` hands it back.
typedef JsonMap = Map<String, Object?>;

/// Reads that answer `null` for a missing or mistyped field, so an agent's
/// extra or oddly typed fields never throw; only `require*` does.
extension JsonMapReads on JsonMap {
  String? string(String key) {
    final value = this[key];
    return value is String ? value : null;
  }

  String requireString(String key) =>
      string(key) ?? (throw FormatException('"$key" missing or not a string'));

  int? integer(String key) {
    final value = this[key];
    if (value is int) return value;
    if (value is double && value == value.truncateToDouble()) {
      return value.toInt();
    }
    return null;
  }

  double? number(String key) {
    final value = this[key];
    return value is num ? value.toDouble() : null;
  }

  bool? boolean(String key) {
    final value = this[key];
    return value is bool ? value : null;
  }

  JsonMap? object(String key) => asJsonMap(this[key]);

  JsonMap requireObject(String key) =>
      object(key) ?? (throw FormatException('"$key" missing or not an object'));

  List<Object?>? list(String key) {
    final value = this[key];
    return value is List ? value : null;
  }

  /// The objects in a list field; anything in it that is not one is skipped.
  List<JsonMap>? objects(String key) {
    final items = list(key);
    if (items == null) return null;
    return [for (final item in items) ?asJsonMap(item)];
  }

  List<String>? strings(String key) {
    final items = list(key);
    if (items == null) return null;
    return [
      for (final item in items)
        if (item is String) item,
    ];
  }
}

/// [value] as a JSON object, or `null` when it is not one.
JsonMap? asJsonMap(Object? value) {
  if (value is JsonMap) return value;
  if (value is Map) return value.cast<String, Object?>();
  return null;
}

/// [json] without its `null` entries, so an optional field is left out of the
/// wire form rather than sent as `null`.
JsonMap withoutNulls(JsonMap json) => {
  for (final entry in json.entries)
    if (entry.value != null) entry.key: entry.value,
};
