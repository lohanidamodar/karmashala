import 'agent_adapter.dart';
import 'agent_rewind.dart';
import 'generic_chat_protocol.dart';

/// The capabilities an `AgentAdapter` may declare, by name — for a surface
/// that lists what an agent can do, and for a test that pins what an agent
/// degrades to. Callers that *act* read the capability itself, never this.
enum AgentCapability {
  /// A chat protocol richer than plain text.
  structuredChat,

  /// A conversation store this package can read.
  store,

  /// Renaming and deleting conversations in that store.
  storeEditing,

  /// Transcripts this package can parse.
  transcripts,

  /// A structured chat view built from those transcripts.
  chatView,

  /// Token and turn accounting.
  stats,

  /// A record of which files a conversation changed.
  fileChanges,

  /// Pictures found in transcripts.
  media,

  /// Something to say about the agent's own undo.
  rewind,

  /// A usage endpoint.
  usage,

  /// Account switching.
  accounts,

  /// A server process over the store.
  storeServer,

  /// A store that records the last conversation per directory.
  directoryConversations,

  /// The CLI's own model list.
  modelListing,

  /// A conversation over the Agent Client Protocol instead of a terminal.
  acp,
}

extension AgentCapabilities on AgentAdapter {
  /// Every capability this adapter declares.
  Set<AgentCapability> get capabilities => {
    if (chatProtocol(_noRunner) is! GenericChatProtocol)
      AgentCapability.structuredChat,
    if (store != null) AgentCapability.store,
    if (store?.editor != null) AgentCapability.storeEditing,
    if (transcripts != null) AgentCapability.transcripts,
    if (transcripts?.buildsChatView ?? false) AgentCapability.chatView,
    if (stats != null) AgentCapability.stats,
    if (fileChanges != null) AgentCapability.fileChanges,
    if (media != null) AgentCapability.media,
    if (rewind is! UnknownRewind) AgentCapability.rewind,
    if (usage != null) AgentCapability.usage,
    if (accounts != null) AgentCapability.accounts,
    if (storeServer != null) AgentCapability.storeServer,
    if (directoryConversations != null) AgentCapability.directoryConversations,
    if (modelLister != null) AgentCapability.modelListing,
    if (acp != null) AgentCapability.acp,
  };
}

/// Building a protocol never resolves a runner — only starting one does.
Never _noRunner(String environmentId) =>
    throw StateError('capabilities never start a run');
