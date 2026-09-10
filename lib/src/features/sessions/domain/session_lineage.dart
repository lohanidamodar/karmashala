/// Why one session has a parent, and what a chain of them looks like.
library;

/// The reason a session names another as its parent. **Stored, unlike depth**:
/// a link kind is a fact about creation that nothing can re-derive later.
enum SessionLink {
  /// An agent asked for this session through MCP. The original meaning of
  /// `parent_session_id`, and the only one before schema v13.
  spawn('spawned by'),

  /// The user moved the work to a different agent. The child shares **no**
  /// agent-level history with the parent — only the text of the packet.
  handoff('handed off from'),

  /// The user branched the conversation. The child starts from the parent's own
  /// history, either because the CLI forked it or because a packet carried it.
  fork('forked from');

  const SessionLink(this.phrase);

  /// How to describe the relationship in a sentence, child-first: "handed off
  /// from *Fix the parser*".
  final String phrase;

  /// Parses a stored value, or `null` for anything unrecognised. Not
  /// `values.byName`, which throws and made a fourth agent's rows unreadable.
  static SessionLink? parse(String? value) {
    if (value == null) return null;
    for (final link in SessionLink.values) {
      if (link.name == value) return link;
    }
    return null;
  }
}

/// One session as it appears in a lineage: enough to draw a row, and nothing
/// that would need a second query per level.
class SessionLineageNode {
  const SessionLineageNode({
    required this.sessionId,
    required this.title,
    required this.link,
    this.agentId,
  });

  final String sessionId;
  final String title;

  /// Why *this* session points at its parent. Null for a root and for a pre-v13
  /// row; [SessionLineage.ancestors] tells the two apart.
  final SessionLink? link;

  /// The agent that ran it, when it is still resolvable. Null is "we cannot
  /// tell any more", never a default agent.
  final String? agentId;

  @override
  bool operator ==(Object other) =>
      other is SessionLineageNode &&
      other.sessionId == sessionId &&
      other.title == title &&
      other.link == link &&
      other.agentId == agentId;

  @override
  int get hashCode => Object.hash(sessionId, title, link, agentId);

  @override
  String toString() => 'SessionLineageNode($sessionId, $title, $link)';
}

/// Where one session sits among the sessions it came from and the ones that
/// came from it, guarded like [SessionDepth]: a cycle would hang the turn.
class SessionLineage {
  const SessionLineage({
    required this.self,
    required this.ancestors,
    required this.children,
    this.chainBroken = false,
  });

  final SessionLineageNode self;

  /// Root first, immediate parent last. Empty for a session the user started.
  final List<SessionLineageNode> ancestors;

  /// Sessions naming [self] as their parent, oldest first.
  final List<SessionLineageNode> children;

  /// The walk hit the guard: the chain does not terminate, so [ancestors] is
  /// **not** a complete answer and must not be drawn as one.
  final bool chainBroken;

  bool get hasParent => ancestors.isNotEmpty;
  bool get isRoot => ancestors.isEmpty;

  /// The immediate parent, or null.
  SessionLineageNode? get parent => ancestors.isEmpty ? null : ancestors.last;

  /// Links to follow before declaring the chain broken rather than long. Same
  /// number as [SessionDepth.maxWalk], and for the same reason.
  static const int maxWalk = 64;

  /// Builds a lineage for [sessionId] from two lookups. Pure, so the walk and
  /// its guard are testable without a database; null when nothing is named.
  static SessionLineage? build(
    String sessionId, {
    required ({SessionLineageNode node, String? parentId})? Function(String id)
    lookup,
    required List<SessionLineageNode> Function(String id) children,
  }) {
    final start = lookup(sessionId);
    if (start == null) return null;

    final ancestors = <SessionLineageNode>[];
    final seen = <String>{sessionId};
    var parentId = start.parentId;
    var broken = false;
    for (var step = 0; parentId != null; step++) {
      if (step >= maxWalk || !seen.add(parentId)) {
        broken = true;
        break;
      }
      final found = lookup(parentId);
      // A parent id that names nothing is an *orphan*, not a broken chain:
      // deleting a parent orphans its children rather than cascading.
      if (found == null) break;
      ancestors.insert(0, found.node);
      parentId = found.parentId;
    }

    return SessionLineage(
      self: start.node,
      ancestors: ancestors,
      children: children(sessionId),
      chainBroken: broken,
    );
  }
}
