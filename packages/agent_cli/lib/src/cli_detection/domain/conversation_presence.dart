/// Whether an agent's own store holds a conversation.
///
/// Three answers rather than a boolean, and the third one is the whole point.
/// A store we could not locate, could not reach, or do not know how to read has
/// told us **nothing** about the conversation, and reporting that as "it is not
/// there" would refuse a perfectly good resume every time a WSL distribution is
/// stopped or a drive is unmounted. Only a store that was read to the end
/// without finding the conversation may say [absent].
enum ConversationPresence {
  /// The store was read and the conversation is in it.
  present,

  /// The store was read **completely** and the conversation is not in it. The
  /// only answer strong enough to refuse a resume on.
  absent,

  /// We could not tell. The store is missing, unreachable, in a format we
  /// cannot read, or the listing failed part way through.
  unknown,
}
