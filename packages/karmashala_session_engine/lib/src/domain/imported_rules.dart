import 'package:agent_cli/read.dart';
import 'package:karmashala_session/session.dart';

import 'session_reads.dart';

/// The rules for CLI conversations imported as read-only history, shared by
/// the server's store and a client's copy.
///
/// A conversation a native `sessions` row records is **superseded**: hidden
/// from every list, never deleted. A row with no conversation id supersedes
/// nothing.

/// The native row that took conversation [externalId] over — the newest — or
/// null. Hiding a record from a list does not stop anyone opening it by id.
String? supersedingSessionIdIn(SessionReads sessions, String externalId) =>
    sessions.getByExternalSessionId(externalId)?.id;

/// The imports still showing as history, in the table's order: most recently
/// updated first (never-updated last), then newest.
List<ImportedSession> visibleImported(
  Iterable<ImportedSession> imported,
  Set<String> heldConversations,
) => [
  for (final row in imported)
    if (!heldConversations.contains(row.externalId)) row,
]..sort(compareImported);

/// `ORDER BY updated_at DESC, created_at DESC` — SQLite puts a NULL last in a
/// descending order — then the id, so two reads never differ.
int compareImported(ImportedSession a, ImportedSession b) {
  final au = a.updatedAt;
  final bu = b.updatedAt;
  if (au != bu) {
    if (au == null) return 1;
    if (bu == null) return -1;
    final byUpdate = bu.compareTo(au);
    if (byUpdate != 0) return byUpdate;
  }
  final byCreated = b.createdAt.compareTo(a.createdAt);
  return byCreated != 0 ? byCreated : a.id.compareTo(b.id);
}

/// Whether [candidate] may be imported: not when that conversation is already
/// imported from the same CLI, nor when a native row already represents it.
bool mayImport(
  ImportedSession candidate, {
  required ImportedSession? existing,
  required bool superseded,
}) => existing == null && !superseded;

/// Whether a session [row] holds the conversation [externalId].
bool holdsConversation(Session row, String externalId) =>
    row.externalSessionId == externalId;
