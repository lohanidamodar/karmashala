import '../domain/file_edit.dart';

/// **Where an agent records which files it changed**, when it records that at
/// all. The caller branches on the kind of record, never on the agent.
sealed class AgentFileChanges {
  const AgentFileChanges();
}

/// The edits are in the transcript, line by line.
final class TranscriptFileEdits extends AgentFileChanges {
  const TranscriptFileEdits(this.editsOnLine);

  /// Every edit recorded on one decoded transcript line.
  final List<FileEditRecord> Function(Map<String, Object?> json) editsOnLine;
}

/// The agent's store server answers for the conversation — see
/// `AgentStoreServerClient.listFileChanges`.
final class StoreServerFileChanges extends AgentFileChanges {
  const StoreServerFileChanges();
}
