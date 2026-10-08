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
  mcp,

  /// A scheduled resume the server fired.
  automation,

  /// Results of sessions this one delegated, pushed when their turns ended;
  /// [QueuedMessage.originId] is the child that opened the row.
  delegation;

  static QueuedMessageOrigin fromName(String? name) => values.firstWhere(
    (origin) => origin.name == name,
    orElse: () => QueuedMessageOrigin.app,
  );
}

/// Why a session's queued messages wait although no turn of its runs.
enum QueueHoldKind {
  /// The agent stopped on its usage limit; [QueueHold.until] is the resume
  /// armed for its reset, when one is.
  limit,

  /// A resume is scheduled for [QueueHold.until], at a chosen time.
  scheduled,

  /// The person stopped or ended the session: nothing more goes until they
  /// send again or ask for the next one.
  paused,

  /// Nothing runs the session, so nothing goes until it is resumed.
  stopped,

  /// The agent's terminal input holds text someone typed there and has not
  /// sent: nothing is typed over it until it is sent or cleared.
  typedInput;

  static QueueHoldKind? fromName(String? name) {
    for (final kind in values) {
      if (kind.name == name) return kind;
    }
    return null;
  }
}

/// What holds a session's queue, and until when where that is known.
class QueueHold {
  const QueueHold(this.kind, {this.until});

  /// Null for a kind this build does not know.
  static QueueHold? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = QueueHoldKind.fromName(json['kind'] as String?);
    if (kind == null) return null;
    return QueueHold(
      kind,
      until: switch (json['until']) {
        final String at => DateTime.tryParse(at),
        _ => null,
      },
    );
  }

  final QueueHoldKind kind;
  final DateTime? until;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'until': ?until?.toUtc().toIso8601String(),
  };

  @override
  bool operator ==(Object other) =>
      other is QueueHold && other.kind == kind && other.until == until;

  @override
  int get hashCode => Object.hash(kind, until);

  @override
  String toString() => 'QueueHold(${kind.name}, until: $until)';
}

/// [QueuedMessage.cancelledBy] for a message its session's ending cancelled.
const String kCancelledBySessionEnd = 'session-ended';

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
    this.cancelledBy,
    this.hold,
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
    cancelledBy: json['cancelledBy'] as String?,
    hold: QueueHold.fromJson(json['hold']),
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

  /// Who cancelled a [QueuedMessageState.cancelled] row: `device:<id>`,
  /// `app`, or [kCancelledBySessionEnd] ([error] then says why). Null on a
  /// row cancelled before it was recorded.
  final String? cancelledBy;

  /// What keeps a queued message waiting past the running turn: never
  /// stored, told by the server as it stands.
  final QueueHold? hold;

  bool get editable => state == QueuedMessageState.queued;

  QueuedMessage copyWith({
    String? text,
    QueuedMessageState? state,
    DateTime? updatedAt,
    DateTime? deliveredAt,
    String? error,
    String? cancelledBy,
    QueueHold? hold,
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
    cancelledBy: cancelledBy ?? this.cancelledBy,
    hold: hold ?? this.hold,
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
    'cancelledBy': ?cancelledBy,
    'hold': ?hold?.toJson(),
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
      other.error == error &&
      other.cancelledBy == cancelledBy &&
      other.hold == hold;

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
    cancelledBy,
    hold,
  );
}
