import '../../agents/adapter/agent_store.dart';
import '../domain/conversation_presence.dart';

/// Answers "does this store hold conversation X" without reading a transcript.
///
/// Deliberately separate from the session readers, which parse every file to
/// build a list. Presence is a question about a *name*, and every store here
/// puts the conversation id in the path — so this is a directory listing and a
/// `stat`, cheap enough to ask before every resume, where a full scan would not
/// be.
///
/// The layout comes from the agent's `AgentStore`, so an agent added tomorrow
/// is answered by its own adapter, and one with no store capability answers
/// [ConversationPresence.unknown] rather than guessing. What lives here is the
/// rule every store shares: an empty question, or a store that threw part way
/// through, told us nothing.
class ConversationStoreIndex {
  const ConversationStoreIndex();

  Future<ConversationPresence> presenceOf({
    required String storeHome,
    required AgentStore? store,
    required String conversationId,
  }) async {
    if (store == null || conversationId.isEmpty || storeHome.isEmpty) {
      return ConversationPresence.unknown;
    }
    try {
      return await store.presenceOf(storeHome, conversationId);
    } on Object {
      // A store that threw part way through told us nothing, and "nothing" is
      // not "absent" — see [ConversationPresence].
      return ConversationPresence.unknown;
    }
  }

  /// Every conversation id one store holds, or `null` when the store told us
  /// nothing — the bulk sibling of [presenceOf], and the whole reason a
  /// housekeeping sweep is affordable.
  ///
  /// [presenceOf] is a question about *one* name and costs one listing, which
  /// is right before a resume. Asking it per row is not the same shape of cost:
  /// a recursive store would be N walks of the same tree. This walks each tree
  /// **once** and hands back the set, so the cost is O(stores) whatever the
  /// number of rows.
  ///
  /// `null` rather than an empty set is load-bearing, and is the same
  /// distinction [ConversationPresence.unknown] draws: a store that is missing,
  /// unreachable, or in a format we cannot read has told us nothing, and an
  /// empty set would say "it holds no conversations at all" — which, used to
  /// decide what to delete, is every row at once.
  Future<Set<String>?> idsIn({
    required String storeHome,
    required AgentStore? store,
  }) async {
    if (store == null || storeHome.isEmpty) return null;
    try {
      return await store.conversationIds(storeHome);
    } on Object {
      // Threw part way through, so the set we have is a partial listing and a
      // partial listing is indistinguishable from a small store. Nothing.
      return null;
    }
  }
}
