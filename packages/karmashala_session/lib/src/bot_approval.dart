import 'record_json.dart';

/// How long a person has to answer a request before it expires.
const Duration kBotApprovalLifetime = Duration(minutes: 10);

/// Where a request stands. Only [pending] can be answered.
enum BotApprovalState {
  /// Waiting for a person.
  pending,

  /// A person said Yes, and the server is running the recorded call.
  running,

  /// The recorded call ran; its result is in `outcome`, a failure's too.
  done,

  /// A person said No. Nothing ran.
  denied,

  /// Nobody answered in time, or the conversation was cleared. Nothing ran.
  expired,

  /// A stop cut the running call off: it may have run, wholly or in part.
  interrupted;

  /// A word this build does not know reads as [expired]: it can never run.
  static BotApprovalState parse(String? value) {
    for (final state in values) {
      if (state.name == value) return state;
    }
    return expired;
  }
}

/// One exact tool call the bot made that cannot be undone, recorded instead of
/// run. Approval covers this call alone: [tool] and [arguments] are what the
/// server runs on Yes, and [summary] is what the person read.
class BotApproval {
  const BotApproval({
    required this.id,
    required this.sessionId,
    required this.tool,
    required this.arguments,
    required this.summary,
    required this.state,
    required this.requestedAt,
    required this.expiresAt,
    this.decidedAt,
    this.decidedBy,
    this.outcome,
  });

  final String id;

  /// The bot row that asked.
  final String sessionId;
  final String tool;
  final Map<String, Object?> arguments;

  /// The tool and its target in plain words.
  final String summary;
  final BotApprovalState state;
  final DateTime requestedAt;
  final DateTime expiresAt;
  final DateTime? decidedAt;

  /// Who answered: `app`, or `device:<id>`.
  final String? decidedBy;

  /// What became of it, in words.
  final String? outcome;

  /// On the wire: everything a client draws, and the [arguments] the person
  /// is agreeing to.
  Map<String, Object?> toJson() => {
    'id': id,
    'sessionId': sessionId,
    'tool': tool,
    'arguments': arguments,
    'summary': summary,
    'state': state.name,
    'requestedAt': jsonDate(requestedAt),
    'expiresAt': jsonDate(expiresAt),
    if (decidedAt case final at?) 'decidedAt': jsonDate(at),
    'decidedBy': ?decidedBy,
    'outcome': ?outcome,
  };

  static BotApproval fromJson(Map<String, Object?> json) => BotApproval(
    id: jsonString(json, 'id'),
    sessionId: jsonString(json, 'sessionId'),
    tool: jsonString(json, 'tool'),
    arguments: (json['arguments'] as Map? ?? const {}).cast<String, Object?>(),
    summary: jsonString(json, 'summary'),
    state: BotApprovalState.parse(jsonOptionalString(json, 'state')),
    requestedAt: jsonDateOf(json, 'requestedAt'),
    expiresAt: jsonDateOf(json, 'expiresAt'),
    decidedAt: jsonOptionalDateOf(json, 'decidedAt'),
    decidedBy: jsonOptionalString(json, 'decidedBy'),
    outcome: jsonOptionalString(json, 'outcome'),
  );
}
