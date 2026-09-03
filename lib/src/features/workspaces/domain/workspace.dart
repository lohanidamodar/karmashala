/// One of the user's contexts — Personal, PopupBits, Appwrite, game dev — that
/// a project may belong to. The level above [Project], and a *scope filter*
/// rather than a navigation level: it narrows the project list, it does not sit
/// in the path to a session.
///
/// **The word means two things in this app, so the UI uses another one.** "The
/// workspace" is already everything the user has added — the `Workspace` menu,
/// "Remove from workspace", `workspace.list` on the wire. That sense is the
/// older one and stays. This one is *a* workspace, one of four, and is called a
/// **context** wherever a human reads it. Internal names stay `workspace`
/// because the schema, the protocol and 400-odd existing call sites do.
class Workspace {
  const Workspace({
    required this.id,
    required this.name,
    required this.createdAt,
    this.description,
  });

  final String id;
  final String name;

  /// What the context is for, in the user's own words, or null.
  ///
  /// Null is an ordinary state, not a blank to be filled: a name is enough to
  /// pick a context by. Where a surface has room for a second line it falls
  /// back to something it can say for free — see `describeWorkspace`.
  final String? description;

  final DateTime createdAt;

  /// `description: null` cannot be expressed by a copy — that is what
  /// [clearDescription] is for, and it is the only field here that can be
  /// removed as well as changed.
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
