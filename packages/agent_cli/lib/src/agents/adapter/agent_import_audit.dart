/// **What an import once took from an agent's store that was not a
/// conversation**, and how to tell from the record itself.
///
/// The import skips such records now; this is for clearing the ones an older
/// import already recorded. Nothing is taken on a guess: a record is only
/// called a non-conversation when its own file says so.
abstract interface class AgentImportAudit {
  /// Whether the record at [path] is a run a tool made rather than a
  /// conversation a person had — true only when the file is here and says
  /// so; false when it is a conversation or cannot be read.
  Future<bool> isNotConversation(String path);

  /// What a removed record is called in a log line: `Codex run`.
  String get recordNoun;
}
