/// An agent hook the session host took on its endpoint and relayed to the app.
class RelayedAgentHook {
  const RelayedAgentHook({
    required this.agentId,
    required this.event,
    required this.body,
    required this.receivedAt,
    this.paneSessionId,
    this.holdId,
  });

  final String agentId;
  final String event;

  /// The hook's JSON payload, as text, as the HTTP route read it.
  final String body;
  final DateTime receivedAt;

  /// The pane's `KARMASHALA_SESSION_ID`, when the hook sent one.
  final String? paneSessionId;

  /// Set when the host is holding the agent until this app replies — a live
  /// `PreToolUse`, so its checkpoint can be taken before the tool runs. Null
  /// when the host answered the agent at once: nothing waited for this app.
  final int? holdId;

  /// The host keeps the latest hook per this key, and so does the app.
  String get sessionKey => paneSessionId ?? 'agent:$agentId';
}
