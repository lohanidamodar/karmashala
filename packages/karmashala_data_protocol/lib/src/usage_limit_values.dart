// A usage limit a session's turn ended on (slice 5c): the server notices it,
// files it, and arms or offers a resume by the Settings choice; a client
// shows the notice — the one part that is presentation.

/// How the server answered a usage limit: what the Settings choice
/// (`usageLimitBehavior`) had it do.
enum UsageLimitOutcome {
  /// A resume at the reset is offered: a client shows the offer, and a
  /// person's "Resume then" arms it.
  offered,

  /// Armed without asking, as the setting says.
  scheduled,

  /// Armed again: this session had resumed at a reset before, and the limit
  /// coming back is what that arrangement was made for.
  renewed,

  /// Arming was refused by the unattended gate, in
  /// [UsageLimitNotice.refusal]'s words; the way into the options is left.
  refused,
}

/// A session's turn ended on its account's usage limit, and what the server
/// did about it.
final class UsageLimitNotice {
  const UsageLimitNotice({
    required this.sessionId,
    required this.agentName,
    required this.windowLabel,
    required this.outcome,
    this.resetsAt,
    this.refusal,
    this.resumeId,
    this.resumeFireAt,
    this.resumeMessage,
  });

  final String sessionId;
  final String agentName;

  /// The window refusing work ("5-hour"), and when it resets.
  final String windowLabel;
  final DateTime? resetsAt;
  final UsageLimitOutcome outcome;
  final String? refusal;

  /// The resume the server armed, when it armed one.
  final String? resumeId;
  final DateTime? resumeFireAt;
  final String? resumeMessage;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'agentName': agentName,
    'windowLabel': windowLabel,
    'outcome': outcome.name,
    'resetsAt': ?resetsAt?.toUtc().toIso8601String(),
    'refusal': ?refusal,
    'resumeId': ?resumeId,
    'resumeFireAt': ?resumeFireAt?.toUtc().toIso8601String(),
    'resumeMessage': ?resumeMessage,
  };

  static UsageLimitNotice fromJson(Map<String, Object?> json) {
    DateTime? time(String key) {
      final value = json[key];
      return value is String ? DateTime.tryParse(value)?.toUtc() : null;
    }

    return UsageLimitNotice(
      sessionId: json['sessionId']! as String,
      agentName: json['agentName']! as String,
      windowLabel: json['windowLabel']! as String,
      outcome: UsageLimitOutcome.values.firstWhere(
        (o) => o.name == json['outcome'],
        orElse: () => throw const FormatException('not a usage-limit outcome'),
      ),
      resetsAt: time('resetsAt'),
      refusal: json['refusal'] as String?,
      resumeId: json['resumeId'] as String?,
      resumeFireAt: time('resumeFireAt'),
      resumeMessage: json['resumeMessage'] as String?,
    );
  }
}
