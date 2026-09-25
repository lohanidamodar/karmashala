/// Where a conversation id came from, in descending order of authority.
enum DirectoryConversationSource {
  /// The CLI printed it. Not a heuristic: the agent stated, in our own pane,
  /// which conversation it was on.
  announcement,

  /// The store named it for the directory we launched in, and the
  /// attributor's guards agreed it is ours.
  lastConversation,
}

/// What was learned about which conversation a session is on.
///
/// A refusal carries [reason] in plain words rather than being empty, because
/// "no CLI session id found" is exactly the message the owner hit and it says
/// nothing about which of the several different situations they are in.
class DirectoryConversationAttribution {
  const DirectoryConversationAttribution.learned(
    String id,
    DirectoryConversationSource from,
  ) : conversationId = id,
      source = from,
      reason = '';

  const DirectoryConversationAttribution.none(this.reason)
    : conversationId = null,
      source = null;

  final String? conversationId;
  final DirectoryConversationSource? source;

  /// Why nothing was learned. Empty when something was.
  final String reason;

  bool get isLearned => conversationId != null;

  @override
  String toString() => isLearned
      ? 'DirectoryConversationAttribution($conversationId via ${source!.name})'
      : 'DirectoryConversationAttribution(none: $reason)';
}
