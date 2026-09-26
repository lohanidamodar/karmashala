/// One of the user's contexts, the level above a project. It is a navigation
/// level in the Explorer — a node inside the machine its projects run on — and
/// a scope for where new work goes. Called a **context** wherever a human reads.
class Workspace {
  const Workspace({
    required this.id,
    required this.name,
    required this.createdAt,
    this.description,
    this.color,
  });

  final String id;
  final String name;

  /// What the context is for, in the user's own words, or null. Null is an
  /// ordinary state: a name is enough to pick a context by.
  final String? description;

  /// The name of a `ContextHue` the user gave it, or null for none — the
  /// default, and the state most contexts stay in. The domain keeps the word,
  /// not the colour: what a name paints is the theme's to say.
  final String? color;

  final DateTime createdAt;

  /// `description: null` and `color: null` cannot be expressed by a copy —
  /// that is what [clearDescription] and [clearColor] are for.
  Workspace copyWith({
    String? id,
    String? name,
    String? description,
    String? color,
    DateTime? createdAt,
    bool clearDescription = false,
    bool clearColor = false,
  }) => Workspace(
    id: id ?? this.id,
    name: name ?? this.name,
    description: clearDescription ? null : (description ?? this.description),
    color: clearColor ? null : (color ?? this.color),
    createdAt: createdAt ?? this.createdAt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'description': ?description,
    'color': ?color,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  /// Throws [FormatException] on a map that is not a context.
  static Workspace fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final name = json['name'];
    final createdAt = json['createdAt'];
    if (id is! String || name is! String || createdAt is! String) {
      throw const FormatException('not a context');
    }
    return Workspace(
      id: id,
      name: name,
      description: json['description'] as String?,
      color: json['color'] as String?,
      createdAt: DateTime.parse(createdAt).toUtc(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Workspace &&
      other.id == id &&
      other.name == name &&
      other.description == description &&
      other.color == color &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(id, name, description, color, createdAt);

  @override
  String toString() => 'Workspace($id, $name)';
}
