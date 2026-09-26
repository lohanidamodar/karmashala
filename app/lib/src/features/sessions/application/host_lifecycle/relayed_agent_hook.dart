/// An agent hook the session host took on its endpoint and relayed to the app.
class RelayedAgentHook {
  const RelayedAgentHook({
    required this.agentId,
    required this.event,
    required this.body,
    required this.receivedAt,
    this.paneSessionId,
  });

  final String agentId;
  final String event;

  /// The hook's JSON payload, as text, as the HTTP route read it.
  final String body;
  final DateTime receivedAt;

  /// The pane's `KARMASHALA_SESSION_ID`, when the hook sent one.
  final String? paneSessionId;

  /// The host keeps the latest hook per this key, and so does the app.
  String get sessionKey => paneSessionId ?? 'agent:$agentId';
}
