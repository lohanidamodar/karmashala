import 'package:karmashala_session/session.dart';

import 'session_list_prefs.dart';

/// A parent's sub-sessions, folded beneath it in the session lists: how many
/// there are, how many run, and whether they start folded.
class SubSessionFold {
  const SubSessionFold({
    required this.parentId,
    required this.count,
    required this.running,
    required this.foldedByDefault,
  });

  /// [descendants] are every session below [parent]; [isLive] says which of
  /// them, and whether the parent, still run or wait on a person.
  factory SubSessionFold.of(
    Session parent,
    Iterable<Session> descendants, {
    required bool Function(Session session) isLive,
  }) {
    var count = 0;
    var running = 0;
    for (final session in descendants) {
      count++;
      if (isLive(session)) running++;
    }
    return SubSessionFold(
      parentId: parent.id,
      count: count,
      running: running,
      // Folded once the parent has ended or every child has: nothing there
      // is moving. A live parent with a live child stays open.
      foldedByDefault: !isLive(parent) || running == 0,
    );
  }

  final String parentId;
  final int count;
  final int running;
  final bool foldedByDefault;

  /// "12 sub-sessions · 2 running".
  String get label {
    final what = '$count sub-session${count == 1 ? '' : 's'}';
    return running == 0 ? what : '$what · $running running';
  }

  /// Whether it is folded on this device: the person's choice, else the
  /// default.
  bool foldedIn(SessionListPrefs prefs) =>
      prefs.folds[parentId] ?? foldedByDefault;
}

/// Whether [session] still runs or waits — kept in sight when its parent's
/// sub-sessions are folded. `unknown` is "lost sight of it", not live.
bool subSessionLive(Session session) =>
    !session.isArchived &&
    (session.status.claimsLive || session.status == SessionStatus.created);
