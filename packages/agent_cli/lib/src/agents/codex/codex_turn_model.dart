/// The model a Codex rollout record sets for what follows: `payload.model` of
/// a `turn_context` (re-stamped every turn, so a `/model` switch shows) or of
/// the opening `session_meta`. Null for every other record.
String? codexTurnModel(Map<String, Object?> json) {
  final type = json['type'];
  if (type != 'turn_context' && type != 'session_meta') return null;
  final payload = json['payload'];
  if (payload is! Map) return null;
  final model = payload['model'];
  return model is String && model.isNotEmpty ? model : null;
}
