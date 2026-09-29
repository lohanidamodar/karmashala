import 'package:agent_cli/descriptors.dart' show AgentRegistry;
import 'package:agent_cli/discovery.dart' show AgentInstallation;
import 'package:karmashala_session/transcript.dart' show ChatViewEvidence;
import 'package:karmashala_session_engine/store.dart'
    show ImportedSessionDao, SessionDao;

/// Where a session's agent keeps its record on this machine, or why there is
/// none to read: [path] is null exactly when [absence] is set.
typedef SessionRecordLookup = ({
  String? path,
  String? agentId,
  ChatViewEvidence? absence,
});

/// **The one rule for finding a session's record here**, shared by the
/// phone's transcript and `sessions.transcript`: an imported session names
/// its file; a row names its agent and conversation, found by [locate].
Future<SessionRecordLookup> lookUpSessionRecord(
  String sessionId, {
  required ImportedSessionDao imported,
  required SessionDao sessions,
  required AgentInstallation? Function(String id) installation,
  required Future<String?> Function(String agentId, String conversationId)
  locate,
  AgentRegistry? registry,
}) async {
  final importedRow = imported.getById(sessionId);
  if (importedRow != null) {
    return (
      path: importedRow.filePath,
      agentId: importedRow.cli,
      absence: null,
    );
  }
  const none = (
    path: null,
    agentId: null,
    absence: ChatViewEvidence.noSessionRecord,
  );
  final row = sessions.getById(sessionId);
  if (row == null) return none;
  final agentId = installation(row.agentInstallationId)?.agentId;
  if (agentId == null) return none;
  if (registry != null) {
    final adapter = registry.adapterFor(agentId);
    if (adapter?.descriptor.store == null || adapter?.store == null) {
      return (
        path: null,
        agentId: agentId,
        absence: ChatViewEvidence.storeUnreadable,
      );
    }
  }
  final conversation = row.externalSessionId;
  if (conversation == null || conversation.isEmpty) {
    return (path: null, agentId: agentId, absence: none.absence);
  }
  String? path;
  try {
    path = await locate(agentId, conversation);
  } on Object {
    path = null;
  }
  return (
    path: path,
    agentId: agentId,
    absence: path == null ? ChatViewEvidence.notLocated : null,
  );
}
