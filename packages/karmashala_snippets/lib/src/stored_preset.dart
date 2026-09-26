/// A saved workbench shape under a name. [shape] is the JSON a
/// `TerminalPreset` writes; the server keeps it without reading it.
class StoredPreset {
  const StoredPreset({
    required this.id,
    required this.name,
    required this.shape,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final Map<String, Object?> shape;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'shape': shape,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  /// Throws [FormatException] on a row out of shape.
  static StoredPreset fromJson(Map<String, Object?> json) {
    final id = json['id'], name = json['name'], shape = json['shape'];
    final updated = DateTime.tryParse('${json['updatedAt']}');
    if (id is! String || name is! String || shape is! Map || updated == null) {
      throw const FormatException('not a terminal preset');
    }
    return StoredPreset(
      id: id,
      name: name,
      shape: shape.cast<String, Object?>(),
      updatedAt: updated.toUtc(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is StoredPreset &&
      other.id == id &&
      other.name == name &&
      other.updatedAt == updatedAt &&
      _sameJson(other.shape, shape);

  @override
  int get hashCode => Object.hash(id, name, updatedAt);
}

bool _sameJson(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_sameJson(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameJson(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// The table's order: the one touched last first, then by name.
int comparePresets(StoredPreset a, StoredPreset b) {
  final byUpdated = b.updatedAt.compareTo(a.updatedAt);
  return byUpdated != 0 ? byUpdated : a.name.compareTo(b.name);
}

/// The id a preset saved as [name] is written under: the one already called
/// that — saving twice under one name is a correction — or [id].
String presetIdFor(String name, String id, Iterable<StoredPreset> saved) {
  for (final preset in saved) {
    if (preset.name == name) return preset.id;
  }
  return id;
}
