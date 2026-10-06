import 'session.dart';
import 'session_patch.dart';

/// What archiving or unarchiving [ids] does among [rows]: each named session
/// and then its descendants, nearest first. A [live] session is left as it
/// is and its descendants are not followed through it; an id no row has is
/// [missing]. Nothing touches a worktree.
({List<Session> changed, List<Session> live, List<String> missing})
planArchive(
  Iterable<Session> rows,
  List<String> ids, {
  required bool archive,
  required DateTime at,
  required bool Function(Session row) isLive,
}) {
  final byId = <String, Session>{};
  final byParent = <String, List<Session>>{};
  for (final row in rows) {
    byId[row.id] = row;
    if (row.parentSessionId case final parent?) {
      (byParent[parent] ??= []).add(row);
    }
  }
  final patch = archive
      ? SessionPatch.archive(at)
      : const SessionPatch.unarchive();
  final changed = <Session>[];
  final live = <Session>[];
  final missing = <String>[];
  final handled = <String>{};

  /// Whether [row] ends up as asked, so its descendants follow it.
  bool consider(Session row) {
    if (!handled.add(row.id)) return false;
    if (row.isArchived == archive) return true;
    if (archive && isLive(row)) {
      live.add(row);
      return false;
    }
    changed.add(patch.applyTo(row));
    return true;
  }

  for (final id in ids.toSet()) {
    final row = byId[id];
    if (row == null) {
      missing.add(id);
      continue;
    }
    if (!consider(row)) continue;
    final queue = [row.id];
    while (queue.isNotEmpty) {
      for (final child in byParent[queue.removeAt(0)] ?? const <Session>[]) {
        if (consider(child)) queue.add(child.id);
      }
    }
  }
  return (changed: changed, live: live, missing: missing);
}
