/// One of the user's contexts, the level above [Project] and a *scope filter*
/// rather than a navigation level. Called a **context** wherever a human reads.
class Workspace {
  const Workspace({
    required this.id,
    required this.name,
    required this.createdAt,
    this.description,
  });

  final String id;
  final String name;

  /// What the context is for, in the user's own words, or null. Null is an
  /// ordinary state: a name is enough to pick a context by.
  final String? description;

  final DateTime createdAt;

  /// `description: null` cannot be expressed by a copy — that is what
  /// [clearDescription] is for.
  Workspace copyWith({
    String? id,
    String? name,
    String? description,
    DateTime? createdAt,
    bool clearDescription = false,
  }) => Workspace(
    id: id ?? this.id,
    name: name ?? this.name,
    description: clearDescription ? null : (description ?? this.description),
    createdAt: createdAt ?? this.createdAt,
  );

  @override
  bool operator ==(Object other) =>
      other is Workspace &&
      other.id == id &&
      other.name == name &&
      other.description == description &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(id, name, description, createdAt);

  @override
  String toString() => 'Workspace($id, $name)';
}
