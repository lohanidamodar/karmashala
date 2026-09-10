import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/resume.dart';
import 'package:karmashala_session/lineage.dart';

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

  /// Why this session names a parent — spawned, handed off, forked. Set whether
  /// or not the parent is drawn above it; what the glyph must never imply is
  /// *which* session it came from when that one is off screen.
  final SessionLink? link;

  /// The parent chain does not terminate: it loops, or it is longer than
  /// [SessionLineage.maxWalk]. A flag rather than a silent fallback — a chain we
  /// could not walk must be drawn as unknown, not as a plausible tree.
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

/// Arranges the sessions drawn on one row into parent-and-child order. Nesting
/// is local to the row, or a child would be drawn twice. Children keep the
/// order the work happened in; a child above its parent breaks the nesting.
List<SessionNode> buildSessionForest(
  List<Session> sessions, {
  required bool Function(String sessionId) isPinned,
  SessionLastActive Function(String sessionId) lastActive = _noReading,
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
    // Walk to a root before nesting anything — the guard `SessionLineage` uses:
    // a cycle must fail the row, not hang the frame that draws it.
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
    return compareByLastActive(
      (lastActive: lastActive(a.id), createdAt: a.createdAt),
      (lastActive: lastActive(b.id), createdAt: b.createdAt),
    );
  });
  return [for (final root in roots) nodeFor(root)];
}

SessionLastActive _noReading(String sessionId) => SessionLastActive.unknown;
