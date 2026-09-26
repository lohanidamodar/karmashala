import 'record_json.dart';

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
