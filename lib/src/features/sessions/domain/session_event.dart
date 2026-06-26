/// A single, immutable record in a session's **append-only** event log.
///
/// Events are the normalized representation of everything that happens in a
/// session (agent output, tool calls, status changes, …). They are never
/// updated or deleted in normal operation; new state is expressed by appending
/// new events. Agent-specific protocol details are translated into these events
/// by an `AgentAdapter` (later loops) — this type is protocol-agnostic.
class SessionEvent {
  const SessionEvent({
    required this.sessionId,
    required this.seq,
    required this.type,
    required this.payload,
    required this.createdAt,
    this.id,
  });

  /// Database rowid; `null` for an event not yet persisted.
  final int? id;

  final String sessionId;

  /// Monotonic per-session sequence number (0-based), assigned on append.
  final int seq;

  /// Normalized event type, e.g. `session.started`, `message.agent`,
  /// `tool.call`. Free-form here; conventions are defined where events are
  /// produced (Loop 6+).
  final String type;

  /// Event body, serialized as a JSON string. Opaque to the store.
  final String payload;

  final DateTime createdAt;

  SessionEvent copyWith({
    int? id,
    String? sessionId,
    int? seq,
    String? type,
    String? payload,
    DateTime? createdAt,
  }) => SessionEvent(
    id: id ?? this.id,
    sessionId: sessionId ?? this.sessionId,
    seq: seq ?? this.seq,
    type: type ?? this.type,
    payload: payload ?? this.payload,
    createdAt: createdAt ?? this.createdAt,
  );

  @override
  bool operator ==(Object other) =>
      other is SessionEvent &&
      other.id == id &&
      other.sessionId == sessionId &&
      other.seq == seq &&
      other.type == type &&
      other.payload == payload &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(id, sessionId, seq, type, payload, createdAt);

  @override
  String toString() => 'SessionEvent($sessionId#$seq, $type)';
}
