import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefused;
import 'package:karmashala_session/lineage.dart' show SessionDepth, SessionLink;
import 'package:karmashala_session/session.dart' show Session;
import 'package:karmashala_session_engine/store.dart'
    show SessionDao, kReportModeFinal;
import 'package:karmashala_store/database.dart';

import 'delegation_results.dart';

/// What the parent's thread says of a session [title] attached under it.
String attachedNote(String title) => '"$title" was attached';

/// **Attaching a top-level session under a parent** — Detach's way back. The
/// session becomes the parent's child: on the parent's card, within its depth,
/// and reporting to it as a `final` delegation ([DelegationResults.attach]).
/// The parent's thread gets one line saying so.
class SessionAttacher {
  SessionAttacher({
    required AppDatabase database,
    required this.announce,
    required this.agentOf,
    this.isLive,
    this.delegations,
    this.note,
    this.log,
    DateTime Function()? now,
  }) : _sessions = SessionDao(database),
       _now = now ?? (() => DateTime.now().toUtc());

  /// Tells every client the rows as they now stand.
  final void Function(Iterable<String> sessionIds) announce;

  /// The display name of [Session]'s agent, for the delegation row.
  final String Function(Session session) agentOf;

  /// Whether something runs row [String] now; null skips the parent check.
  final bool Function(String sessionId)? isLive;

  /// The follows to arm; null where this server follows none.
  final DelegationResults? delegations;

  /// Writes the parent's line; null where this server keeps no visuals.
  final Future<void> Function(String parentId, Session child)? note;
  final void Function(String message)? log;

  final SessionDao _sessions;
  final DateTime Function() _now;

  /// Attaches [childId] under [parentId], answered with its row as it now
  /// stands. Refused `notFound` for a session that is gone, `invalid` for a
  /// loop, past the depth cap, an archived session, one already under a
  /// parent, or a parent nothing runs that has no conversation to resume.
  Future<Session> attach(String childId, String parentId) async {
    final child = _found(childId);
    final parent = _found(parentId);
    _check(child, parent);
    _sessions.setParent(childId, parentId, SessionLink.spawn);
    delegations?.attach(
      DelegatedChild(
        childId: childId,
        parentId: parentId,
        title: child.title,
        agent: agentOf(child),
        model: child.modelId,
        startedAt: _now(),
        reportMode: kReportModeFinal,
      ),
    );
    announce([childId]);
    try {
      await note?.call(parentId, child);
    } on Object catch (error) {
      // The attach stands without its line.
      log?.call('attach $childId: the note on $parentId failed: $error');
    }
    log?.call('attach $childId: under $parentId');
    return _sessions.getById(childId)!;
  }

  Session _found(String id) =>
      _sessions.getById(id) ??
      (throw DataRefused.notFound('no session with id $id'));

  void _check(Session child, Session parent) {
    if (child.isArchived) {
      throw DataRefused.invalid(
        '"${child.title}" is archived. Unarchive it first.',
      );
    }
    if (parent.isArchived) {
      throw DataRefused.invalid(
        '"${parent.title}" is archived, so it can hear from nothing.',
      );
    }
    if (child.parentSessionId case final current?) {
      final under = _sessions.getById(current)?.title ?? current;
      throw DataRefused.invalid(
        '"${child.title}" is already under "$under". Detach it first.',
      );
    }
    if (child.id == parent.id || _isAbove(child.id, parent.id)) {
      throw DataRefused.invalid(
        '"${parent.title}" is "${child.title}" or one of its sub-sessions, '
        'so attaching would make a loop.',
      );
    }
    final depth = SessionDepth.forChildOf(parent.id, _sessions.parentOf);
    if (!depth.isAllowed) {
      throw DataRefused.invalid(
        'Sessions nest at most ${SessionDepth.maxDepth} levels deep, and '
        '"${child.title}" would sit at level ${depth.depth}.',
      );
    }
    final deepest = depth.depth + _height(child.id);
    if (deepest > SessionDepth.maxDepth) {
      throw DataRefused.invalid(
        'Sessions nest at most ${SessionDepth.maxDepth} levels deep, and '
        '"${child.title}"\'s own sub-sessions would sit at level $deepest.',
      );
    }
    final live = isLive;
    if (live != null && !live(parent.id) && parent.externalSessionId == null) {
      throw DataRefused.invalid(
        '"${parent.title}" is not running and has no conversation to resume, '
        'so nothing would read its reports.',
      );
    }
  }

  /// Whether [ancestorId] is above [id] in its parent chain.
  bool _isAbove(String ancestorId, String id) {
    final seen = <String>{};
    String? current = _sessions.parentOf(id);
    while (current != null && seen.add(current)) {
      if (current == ancestorId) return true;
      current = _sessions.parentOf(current);
    }
    return false;
  }

  /// Levels of sub-sessions under [id]; 0 for none.
  int _height(String id, [int walked = 0]) {
    if (walked >= SessionDepth.maxWalk) return walked;
    var most = 0;
    for (final child in _sessions.childrenOf(id)) {
      final below = 1 + _height(child.id, walked + 1);
      if (below > most) most = below;
    }
    return most;
  }
}
