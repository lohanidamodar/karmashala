import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/read.dart' show ImportedSession;
import 'session_ui_providers.dart';

/// Moves the selection off the read-only history a native row has just
/// superseded — the server learned which conversation the row is on
/// (launched or directory attribution), and the detail pane resolves by id
/// and would go on showing the history.
///
/// [importedById] reads the history rows: this runs inside the sessions
/// copy's own provider, which the imported sessions' provider is built on.
void followSupersededHistory(
  Ref ref,
  String sessionId,
  String conversationId, {
  required ImportedSession? Function(String id) importedById,
}) {
  final selected = ref.read(selectedImportedSessionIdProvider);
  if (selected == null) return;
  final record = importedById(selected);
  // Only the record this row just took over. Another conversation's history
  // is what the person asked to look at.
  if (record == null || record.externalId != conversationId) return;
  ref.read(selectedImportedSessionIdProvider.notifier).select(null);
  ref.read(selectedSessionIdProvider.notifier).select(sessionId);
}
