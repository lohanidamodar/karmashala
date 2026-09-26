import 'record_json.dart';

/// How many messages one session may send another within
/// [relayBudgetWindow]. Generous: it bounds two sessions trading turns
/// forever, not ordinary coordination (docs/inter-agent-communication.md §4.5).
const int relayBudget = 20;
const Duration relayBudgetWindow = Duration(minutes: 10);

/// One message a session sent another through `session_send`. The
/// `session_relays` record is append-only, so "who told this session to do
/// that" survives a restart (docs/inter-agent-communication.md §4.2).
class SessionRelay {
  const SessionRelay({
    required this.fromSessionId,
    required this.toSessionId,
    required this.text,
    required this.at,
  });

  final String fromSessionId;
  final String toSessionId;

  /// As the sender wrote it, without the attribution line the recipient saw.
  final String text;
  final DateTime at;

  Map<String, Object?> toJson() => {
    'from': fromSessionId,
    'to': toSessionId,
    'text': text,
    'at': jsonDate(at),
  };

  static SessionRelay fromJson(Map<String, Object?> json) => SessionRelay(
    fromSessionId: jsonString(json, 'from'),
    toSessionId: jsonString(json, 'to'),
    text: jsonString(json, 'text'),
    at: jsonDateOf(json, 'at'),
  );
}
