/// One saved Explorer section as the server keeps it: its definition, never a
/// rule section's membership. What the rule *means* — which sessions it
/// matches — is the client's to work out from facts only it has measured;
/// [kind] is kept as the word, so a rule a newer build named survives an
/// older one.
class StoredSection {
  const StoredSection({
    required this.id,
    required this.name,
    required this.kind,
    required this.position,
    this.pattern,
    this.collapsed = true,
    this.members = const {},
  });

  /// The rule kind whose membership is the user's own list.
  static const manualKind = 'manual';

  /// The built-in Pinned section, which cannot be deleted, renamed or moved.
  static const pinnedKind = 'pinned';

  final String id;
  final String name;
  final String kind;
  final String? pattern;

  /// Sidebar order, ascending — also its priority.
  final int position;
  final bool collapsed;

  /// The sessions put here by hand; only a [manualKind] section keeps any.
  final Set<String> members;

  StoredSection copyWith({
    String? name,
    int? position,
    bool? collapsed,
    Set<String>? members,
  }) => StoredSection(
    id: id,
    name: name ?? this.name,
    kind: kind,
    pattern: pattern,
    position: position ?? this.position,
    collapsed: collapsed ?? this.collapsed,
    members: members ?? this.members,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'kind': kind,
    'pattern': ?pattern,
    'position': position,
    'collapsed': collapsed,
    'members': [...members],
  };

  /// Throws [FormatException] on a map that is not a section.
  static StoredSection fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final name = json['name'];
    final kind = json['kind'];
    final position = json['position'];
    final members = json['members'] ?? const <Object?>[];
    if (id is! String ||
        name is! String ||
        kind is! String ||
        position is! int ||
        members is! List) {
      throw const FormatException('not a section');
    }
    return StoredSection(
      id: id,
      name: name,
      kind: kind,
      pattern: json['pattern'] as String?,
      position: position,
      collapsed: json['collapsed'] != false,
      members: {for (final member in members) member as String},
    );
  }

  @override
  bool operator ==(Object other) =>
      other is StoredSection &&
      other.id == id &&
      other.name == name &&
      other.kind == kind &&
      other.pattern == pattern &&
      other.position == position &&
      other.collapsed == collapsed &&
      other.members.length == members.length &&
      other.members.containsAll(members);

  @override
  int get hashCode => Object.hash(
    id,
    name,
    kind,
    pattern,
    position,
    collapsed,
    Object.hashAllUnordered(members),
  );

  @override
  String toString() => 'StoredSection($id "$name" $kind @$position)';
}
