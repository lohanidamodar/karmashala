/// One stretch of a session run by one agent: a switch ends a span and
/// starts the next. A session with none ran a single agent throughout.
class SessionAgentSpan {
  const SessionAgentSpan({
    required this.sessionId,
    required this.seq,
    required this.agentInstallationId,
    required this.startedAt,
    this.externalSessionId,
    this.firstMessageOrdinal,
    this.carriedPacket,
  });

  factory SessionAgentSpan.fromJson(Map<String, Object?> json) =>
      SessionAgentSpan(
        sessionId: json['sessionId']! as String,
        seq: (json['seq'] as num?)?.toInt() ?? 0,
        agentInstallationId: json['agentInstallationId']! as String,
        startedAt: DateTime.parse(json['startedAt']! as String).toUtc(),
        externalSessionId: json['externalSessionId'] as String?,
        firstMessageOrdinal: (json['firstMessageOrdinal'] as num?)?.toInt(),
        carriedPacket: json['carriedPacket'] as String?,
      );

  final String sessionId;

  /// 0, 1, 2… in switch order.
  final int seq;
  final String agentInstallationId;

  /// That agent's own conversation; null until it named one. The active
  /// span's is the row's `externalSessionId`, written here when it ends.
  final String? externalSessionId;
  final DateTime startedAt;

  /// The first `session_messages` ordinal written in this span — set for a
  /// span whose agent's turns the server keeps, null otherwise.
  final int? firstMessageOrdinal;

  /// What the agent was handed on the way in; null for span 0.
  final String? carriedPacket;

  SessionAgentSpan copyWith({String? externalSessionId}) => SessionAgentSpan(
    sessionId: sessionId,
    seq: seq,
    agentInstallationId: agentInstallationId,
    startedAt: startedAt,
    externalSessionId: externalSessionId ?? this.externalSessionId,
    firstMessageOrdinal: firstMessageOrdinal,
    carriedPacket: carriedPacket,
  );

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'seq': seq,
    'agentInstallationId': agentInstallationId,
    'externalSessionId': ?externalSessionId,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'firstMessageOrdinal': ?firstMessageOrdinal,
    'carriedPacket': ?carriedPacket,
  };

  @override
  bool operator ==(Object other) =>
      other is SessionAgentSpan &&
      other.sessionId == sessionId &&
      other.seq == seq &&
      other.agentInstallationId == agentInstallationId &&
      other.externalSessionId == externalSessionId &&
      other.startedAt == startedAt &&
      other.firstMessageOrdinal == firstMessageOrdinal &&
      other.carriedPacket == carriedPacket;

  @override
  int get hashCode => Object.hash(
    sessionId,
    seq,
    agentInstallationId,
    externalSessionId,
    startedAt,
    firstMessageOrdinal,
    carriedPacket,
  );

  @override
  String toString() =>
      'SessionAgentSpan($sessionId#$seq $agentInstallationId '
      '${externalSessionId ?? '-'})';
}
