/// What a session concluded, written by the session's own CLI, on request.
/// **Never** on a tick, at launch, or at the end: each one spends a turn.
library;

import 'record_json.dart';

/// The request every recap is written from, **fixed** for every CLI: a
/// per-agent prompt would make two recaps of one conversation incomparable.
const String kSessionRecapRequest =
    'You are writing a recap of the conversation below for the person who left '
    'this session and is returning to it later. Write three sections, in this '
    'order, with these headings and nothing else:\n\n'
    'Concluded — what this session settled or finished.\n'
    'Left — what is unfinished, and the next step it points at.\n'
    'Do not — what was ruled out here, so it is not tried again.\n\n'
    'Use only what the conversation says. Where it says nothing under a '
    'heading, write "nothing" under that heading rather than inventing one. Be '
    'brief: a few lines per section, no preamble and no closing remarks.';

/// The recap stored for one session (schema v48). [turnCount] makes an age
/// readable as staleness — counted, never timed.
class SessionRecap {
  const SessionRecap({
    required this.sessionId,
    required this.text,
    required this.agentId,
    required this.turnCount,
    required this.writtenAt,
    this.model,
  });

  final String sessionId;

  /// What the CLI wrote, quoted rather than reformatted.
  final String text;

  /// Which CLI wrote it. Two CLIs reading one conversation are two readings.
  final String agentId;

  /// The model it was asked for, or null when the CLI was not told one and ran
  /// its own default. Never backfilled — see the v48 migration.
  final String? model;

  /// How many turns of the conversation this recap read.
  final int turnCount;

  final DateTime writtenAt;

  /// Whether the conversation has grown since this was written.
  bool isStaleAgainst(int turnsNow) => turnsNow > turnCount;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'text': text,
    'agentId': agentId,
    'model': ?model,
    'turnCount': turnCount,
    'writtenAt': jsonDate(writtenAt),
  };

  static SessionRecap fromJson(Map<String, Object?> json) => SessionRecap(
    sessionId: jsonString(json, 'sessionId'),
    text: jsonString(json, 'text'),
    agentId: jsonString(json, 'agentId'),
    model: jsonOptionalString(json, 'model'),
    turnCount: jsonInt(json, 'turnCount'),
    writtenAt: jsonDateOf(json, 'writtenAt'),
  );

  @override
  bool operator ==(Object other) =>
      other is SessionRecap &&
      other.sessionId == sessionId &&
      other.text == text &&
      other.agentId == agentId &&
      other.model == model &&
      other.turnCount == turnCount &&
      other.writtenAt == writtenAt;

  @override
  int get hashCode =>
      Object.hash(sessionId, text, agentId, model, turnCount, writtenAt);
}
