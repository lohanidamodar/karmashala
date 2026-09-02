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
  });

  final String id;
  final String name;
  final DateTime createdAt;

  Workspace copyWith({String? id, String? name, DateTime? createdAt}) =>
      Workspace(
        id: id ?? this.id,
        name: name ?? this.name,
        createdAt: createdAt ?? this.createdAt,
      );

  @override
  bool operator ==(Object other) =>
      other is Workspace &&
      other.id == id &&
      other.name == name &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(id, name, createdAt);

  @override
  String toString() => 'Workspace($id, $name)';
}
