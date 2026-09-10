/// What a session concluded, written by the session's own CLI, on request.
///
/// A recap is for the conversation you come back to after a day. It is **never**
/// produced on a tick, at launch, or when a session ends: every recap spends a
/// turn of the owner's quota, and a digest nobody asked for is a bill nobody
/// agreed to. Auto-naming was refused for the same arithmetic and stays refused.
library;

/// The request every recap is written from, unchanged for every CLI.
///
/// **Fixed, and asserted as fixed.** A prompt that differed per agent would
/// make two recaps of one conversation incomparable. The three headings — what
/// was concluded, what is left, what not to do — are in the order a returning
/// reader needs them. The closing sentence refuses an invented "next step" in a
/// session that has none.
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

/// The recap stored for one session (schema v48).
///
/// [turnCount] is what makes an age readable as staleness: the card compares it
/// against the turns the transcript holds *now*. Counted, never timed — a
/// session can sit untouched for a week and its recap stays as true as the day
/// it was written.
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
}
