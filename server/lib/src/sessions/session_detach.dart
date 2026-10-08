import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefused;
import 'package:karmashala_session/session.dart' show Session;
import 'package:karmashala_session_engine/store.dart'
    show SessionDao, SessionDelegationDao;
import 'package:karmashala_store/database.dart';

import 'delegation_results.dart';

/// What the parent's thread says of a child [title] detached from it.
String detachedNote(String title) => '"$title" was detached';

/// **Detaching a sub-session from its parent** — a person's Detach and a
/// parent's `delegation_detach` alike. The child becomes a top-level session:
/// it leaves the parent's card, its nesting depth and the parent's Done hold,
/// and keeps its transcript, worktree and project. Nothing is delivered
/// either way any more ([DelegationResults.detach]), and the parent's thread
/// gets one line saying so.
///
/// Not undone here: the delegation it had is gone, and attaching a session
/// to a parent is not something either side can ask for.
class SessionDetacher {
  SessionDetacher({
    required AppDatabase database,
    required this.announce,
    this.delegations,
    this.note,
    this.log,
  }) : _sessions = SessionDao(database),
       _store = SessionDelegationDao(database);

  /// Tells every client the rows as they now stand.
  final void Function(Iterable<String> sessionIds) announce;

  /// The follows to drop; null where this server follows none, and only the
  /// delegation row goes.
  final DelegationResults? delegations;

  /// Writes the parent's line; null where this server keeps no visuals.
  final Future<void> Function(String parentId, Session child)? note;
  final void Function(String message)? log;

  final SessionDao _sessions;
  final SessionDelegationDao _store;

  /// Detaches [childId], answered with its row as it now stands. With [by] —
  /// a parent asking through its tool — only that parent's child is taken.
  /// Refused `notFound` for a session that is gone, `invalid` for one with no
  /// parent or another session's.
  Future<Session> detach(String childId, {String? by}) async {
    final child =
        _sessions.getById(childId) ??
        (throw DataRefused.notFound('no session with id $childId'));
    final parentId = child.parentSessionId;
    if (parentId == null) {
      throw DataRefused.invalid(
        '"${child.title}" was started on its own, so there is no parent to '
        'detach it from.',
      );
    }
    if (by != null && by != parentId) {
      throw DataRefused.invalid(
        'Session $childId is not one you started; delegations lists the ones '
        'you did.',
      );
    }
    _sessions.clearParent(childId);
    final follows = delegations;
    if (follows != null) {
      follows.detach(childId, parentId: parentId);
    } else {
      _store.remove(childId);
    }
    announce([childId]);
    try {
      await note?.call(parentId, child);
    } on Object catch (error) {
      // The detach stands without its line.
      log?.call('detach $childId: the note on $parentId failed: $error');
    }
    log?.call('detach $childId: from $parentId${by == null ? '' : ' by it'}');
    return _sessions.getById(childId)!;
  }
}
