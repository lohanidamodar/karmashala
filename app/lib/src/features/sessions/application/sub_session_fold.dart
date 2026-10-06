import 'package:karmashala_session/session.dart';

import 'session_list_prefs.dart';

/// A parent's sub-sessions, folded beneath it in the session lists: how many
/// there are and how many run. Folded unless this device opened it.
class SubSessionFold {
  const SubSessionFold({
    required this.parentId,
    required this.count,
    required this.running,
  });

  /// [descendants] are every session below [parent]; [isLive] says which of
  /// them still run or wait on a person.
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
    return SubSessionFold(parentId: parent.id, count: count, running: running);
  }

  final String parentId;
  final int count;
  final int running;

  /// "12 sub-sessions · 2 running".
  String get label {
    final what = '$count sub-session${count == 1 ? '' : 's'}';
    return running == 0 ? what : '$what · $running running';
  }

  /// Whether it is folded on this device: the person's choice, else folded —
  /// the live ones stay in sight beneath the fold line regardless.
  bool foldedIn(SessionListPrefs prefs) => prefs.folds[parentId] ?? true;
}

/// Whether [session] still runs or waits — kept in sight when its parent's
/// sub-sessions are folded. `unknown` is "lost sight of it", not live.
bool subSessionLive(Session session) =>
    !session.isArchived &&
    (session.status.claimsLive || session.status == SessionStatus.created);

/// [items] with the live ones first, then the rest, newest first in each:
/// the subagents panel's order.
List<T> runningFirst<T>(
  Iterable<T> items, {
  required bool Function(T item) isLive,
  required DateTime Function(T item) createdAt,
}) {
  final live = <T>[];
  final rest = <T>[];
  for (final item in items) {
    (isLive(item) ? live : rest).add(item);
  }
  int newest(T a, T b) => createdAt(b).compareTo(createdAt(a));
  return [...live..sort(newest), ...rest..sort(newest)];
}
