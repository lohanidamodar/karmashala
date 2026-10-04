/// How an agent runs in a session: its CLI in a terminal, or spoken to over
/// a protocol (`AgentDescriptor.acp`) and shown as a chat.
enum AgentRunForm {
  terminal,
  chat;

  /// The form stored as [name], or [terminal] for anything else.
  static AgentRunForm parse(Object? name) =>
      values.where((f) => f.name == name).firstOrNull ?? terminal;

  String get label => switch (this) {
    terminal => 'Terminal',
    chat => 'Chat',
  };
}

/// **One agent as a person reads it**: the descriptors that are forms of it.
///
/// A chat descriptor names the terminal descriptor it is the chat form of
/// (`AgentDescriptor.chatFormOf`); the pair folds to one agent under the
/// terminal id. Descriptors, installations and sessions keep their own ids —
/// this is only how they are grouped where they are listed.
class AgentForms {
  const AgentForms({
    required this.agentId,
    required this.displayName,
    this.terminalId,
    this.chatId,
  });

  /// The folded agent's id: the terminal form's when it has one.
  final String agentId;
  final String displayName;
  final String? terminalId;
  final String? chatId;

  bool get hasBoth => terminalId != null && chatId != null;

  /// The forms this agent has, terminal first.
  List<AgentRunForm> get forms => [
    if (terminalId != null) AgentRunForm.terminal,
    if (chatId != null) AgentRunForm.chat,
  ];

  /// Both descriptor ids, terminal first.
  List<String> get ids => [?terminalId, ?chatId];

  String? idFor(AgentRunForm form) => switch (form) {
    AgentRunForm.terminal => terminalId,
    AgentRunForm.chat => chatId,
  };

  @override
  bool operator ==(Object other) =>
      other is AgentForms &&
      other.agentId == agentId &&
      other.terminalId == terminalId &&
      other.chatId == chatId;

  @override
  int get hashCode => Object.hash(agentId, terminalId, chatId);

  @override
  String toString() => 'AgentForms($agentId: $terminalId, $chatId)';
}
