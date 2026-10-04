/// `session/update` kinds a Karmashala bridge sends for what ACP v1 has no
/// update for. ACP leaves extensions to names starting with an underscore; an
/// ACP agent never sends these, and a client that does not know them ignores
/// them.
abstract final class AcpExtensions {
  /// The agent compacted its context: `trigger` (`manual`, `auto`) when it
  /// said, and `summary`, what it kept.
  static const compaction = '_karmashala/compaction';

  /// The agent started (`state: started`) or finished (`state: ended`) a
  /// turn no prompt asked for, such as a background task's report.
  static const agentTurn = '_karmashala/agent_turn';

  /// The `messageId` of the row a compaction writes, followed by
  /// `:<trigger>` when there is one.
  static const compactionMessageId = '_karmashala/compaction';
}
