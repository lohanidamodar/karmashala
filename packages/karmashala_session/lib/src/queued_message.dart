/// Where a queued message stands. Only [queued] may be edited or cancelled;
/// a row found [delivering] when the server starts is [failed], never resent.
enum QueuedMessageState {
  queued,
  delivering,
  delivered,
  cancelled,
  failed;

  static QueuedMessageState fromName(String? name) => values.firstWhere(
    (state) => state.name == name,
    orElse: () => QueuedMessageState.failed,
  );

  /// Still shown beside the session: waiting, on its way, or failed and not
  /// yet dismissed.
  bool get isOpen => this == queued || this == delivering || this == failed;
}

/// Who sent a queued message.
enum QueuedMessageOrigin {
  /// This machine's own app.
  app,

  /// A paired client over the data link; [QueuedMessage.originId] is the
  /// device.
  device,

  /// A phone on the older companion API.
  companion,

  /// An agent's `session_send`; [QueuedMessage.originId] is the calling
  /// session, when there is one.
  mcp;

  static QueuedMessageOrigin fromName(String? name) => values.firstWhere(
    (origin) => origin.name == name,
    orElse: () => QueuedMessageOrigin.app,
  );
}

/// A message sent while its session's turn ran, kept at the server and
/// delivered one per turn in [seq] order.
class QueuedMessage {
  const QueuedMessage({
    required this.id,
    required this.sessionId,
    required this.seq,
    required this.text,
    required this.state,
    required this.origin,
    required this.createdAt,
    required this.updatedAt,
    this.originId,
    this.deliveredAt,
    this.requestId,
    this.error,
  });

  factory QueuedMessage.fromJson(Map<String, Object?> json) => QueuedMessage(
    id: json['id']! as String,
    sessionId: json['sessionId']! as String,
    seq: (json['seq'] as num?)?.toInt() ?? 0,
    text: json['text'] as String? ?? '',
    state: QueuedMessageState.fromName(json['state'] as String?),
    origin: QueuedMessageOrigin.fromName(json['origin'] as String?),
    originId: json['originId'] as String?,
    createdAt: DateTime.parse(json['createdAt']! as String),
    updatedAt: DateTime.parse(json['updatedAt']! as String),
    deliveredAt: switch (json['deliveredAt']) {
      final String at => DateTime.parse(at),
      _ => null,
    },
    requestId: json['requestId'] as String?,
    error: json['error'] as String?,
  );

  final String id;
  final String sessionId;
  final int seq;
  final String text;
  final QueuedMessageState state;
  final QueuedMessageOrigin origin;
  final String? originId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deliveredAt;

  /// The sender's key for one act, so a resend is answered with this row.
  final String? requestId;

  /// Why a [QueuedMessageState.failed] row failed, in words.
  final String? error;

  bool get editable => state == QueuedMessageState.queued;

  QueuedMessage copyWith({
    String? text,
    QueuedMessageState? state,
    DateTime? updatedAt,
    DateTime? deliveredAt,
    String? error,
  }) => QueuedMessage(
    id: id,
    sessionId: sessionId,
    seq: seq,
    text: text ?? this.text,
    state: state ?? this.state,
    origin: origin,
    originId: originId,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deliveredAt: deliveredAt ?? this.deliveredAt,
    requestId: requestId,
    error: error ?? this.error,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'sessionId': sessionId,
    'seq': seq,
    'text': text,
    'state': state.name,
    'origin': origin.name,
    'originId': ?originId,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'deliveredAt': ?deliveredAt?.toUtc().toIso8601String(),
    'requestId': ?requestId,
    'error': ?error,
  };

  @override
  bool operator ==(Object other) =>
      other is QueuedMessage &&
      other.id == id &&
      other.sessionId == sessionId &&
      other.seq == seq &&
      other.text == text &&
      other.state == state &&
      other.origin == origin &&
      other.originId == originId &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt &&
      other.deliveredAt == deliveredAt &&
      other.requestId == requestId &&
      other.error == error;

  @override
  int get hashCode => Object.hash(
    id,
    sessionId,
    seq,
    text,
    state,
    origin,
    originId,
    createdAt,
    updatedAt,
    deliveredAt,
    requestId,
    error,
  );
}
