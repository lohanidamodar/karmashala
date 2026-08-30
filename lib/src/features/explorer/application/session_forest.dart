import '../../sessions/domain/session.dart';
import '../../sessions/domain/session_lineage.dart';

/// One session as the tree draws it, with the sessions that came from it
/// hanging underneath.
class SessionNode {
  const SessionNode({
    required this.session,
    this.link,
    this.lineageBroken = false,
    this.children = const [],
  });

  final Session session;

  /// Why this session names a parent — spawned, handed off, forked. Null for a
  /// session the user started themselves.
  ///
  /// Set whether or not the parent is drawn above it: a fork whose parent lives
  /// in another checkout is still a fork, and saying so is more useful than
  /// silence. What the glyph must never imply is *which* session it came from
  /// when that one is not on screen — see [SessionCard]'s tooltip.
  final SessionLink? link;

  /// The parent chain does not terminate: it loops, or it is longer than
  /// [SessionLineage.maxWalk].
  ///
  /// Loop 54's rule, and the reason this is a flag rather than a silent
  /// fallback: a chain we could not walk must be drawn as *unknown*, never as a
  /// complete tree with a plausible-looking root. A broken session is placed at
  /// the top of its row and says so.
  final bool lineageBroken;

  /// Oldest first — the order the work actually happened in.
  final List<SessionNode> children;

  /// This node and everything beneath it, depth-first.
  Iterable<SessionNode> get flattened sync* {
    yield this;
    for (final child in children) {
      yield* child.flattened;
    }
  }
}

/// Arranges the sessions drawn on one row into parent-and-child order.
///
/// Nesting is deliberately **local to the row**. A handoff that moved the work
/// into a worktree has its child on the worktree's row, where the work is, and
/// drawing it a second time under its parent would say there are two sessions.
/// So a session is nested only when its parent is on the same row; otherwise it
/// sits at the top level and keeps its link glyph.
///
/// [isPinned] orders the top level the way the flat list always has — pinned
/// first, then most recently created. Children are never re-ordered by pinning:
/// a child that jumped above its parent would break the one thing the nesting
/// is there to show.
List<SessionNode> buildSessionForest(
  List<Session> sessions, {
  required bool Function(String sessionId) isPinned,
}) {
  if (sessions.isEmpty) return const [];
  final byId = {for (final session in sessions) session.id: session};

  // child id -> parent id, for the pairs it is safe to draw as a tree.
  final parentOf = <String, String>{};
  final broken = <String>{};

  for (final session in sessions) {
    final parentId = session.parentSessionId;
    if (parentId == null || !byId.containsKey(parentId)) continue;
    if (parentId == session.id) {
      broken.add(session.id);
      continue;
    }
    // Walk to a root before nesting anything. The same guard `SessionDepth` and
    // `SessionLineage` use, for the same reason: a cycle must fail the row, not
    // hang the frame that draws it.
    final seen = <String>{session.id};
    var cursor = parentId;
    var walkable = true;
    for (var step = 0; ; step++) {
      if (step >= SessionLineage.maxWalk || !seen.add(cursor)) {
        walkable = false;
        break;
      }
      final next = byId[cursor]?.parentSessionId;
      if (next == null || !byId.containsKey(next)) break;
      cursor = next;
    }
    if (walkable) {
      parentOf[session.id] = parentId;
    } else {
      broken.add(session.id);
    }
  }

  final childrenOf = <String, List<Session>>{};
  final roots = <Session>[];
  for (final session in sessions) {
    final parentId = parentOf[session.id];
    if (parentId == null) {
      roots.add(session);
    } else {
      (childrenOf[parentId] ??= []).add(session);
    }
  }

  SessionNode nodeFor(Session session) {
    final children = [...?childrenOf[session.id]]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return SessionNode(
      session: session,
      link: session.parentSessionId == null
          ? null
          // A parent with no stated reason is a spawn — the only way a session
          // could acquire one before schema v13, and what the launcher stamps.
          : (session.parentLink ?? SessionLink.spawn),
      lineageBroken: broken.contains(session.id),
      children: [for (final child in children) nodeFor(child)],
    );
  }

  roots.sort((a, b) {
    final pinnedA = isPinned(a.id);
    final pinnedB = isPinned(b.id);
    if (pinnedA != pinnedB) return pinnedA ? -1 : 1;
    return b.createdAt.compareTo(a.createdAt);
  });
  return [for (final root in roots) nodeFor(root)];
}
