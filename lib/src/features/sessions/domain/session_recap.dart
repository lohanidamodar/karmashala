/// What a session concluded, written by the session's own CLI, on request.
///
/// A recap is for the conversation you come back to after a day — the one whose
/// last screen is a tool result and whose point is forty turns above it. It is
/// **never** produced on a tick, at launch, or when a session ends: every recap
/// spends a turn of the owner's quota, and a digest nobody asked for is a bill
/// nobody agreed to. Auto-naming was refused for the same arithmetic and stays
/// refused — all three CLIs name their own sessions.
library;

/// The request every recap is written from, unchanged for every CLI.
///
/// **Fixed, and asserted as fixed.** A prompt that differs per agent would make
/// two recaps of one conversation incomparable, and a prompt built at the call
/// site would drift with whoever last touched the call site. The three headings
/// are the shape the decision asked for — what was concluded, what is left,
/// what not to do — and they are in that order because that is the order a
/// returning reader needs them in: the conclusion orients, the remainder is the
/// next move, and the refusals are what stops the next hour repeating the last.
///
/// The closing sentence is the §19 rule in prompt form. A model asked for three
/// headings will fill three headings, and an invented "next step" in a session
/// that has none is exactly the confident false statement this app deletes
/// everywhere else.
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
/// [turnCount] is what makes an age readable as staleness. The card compares it
/// against the turns the transcript holds *now*: equal means this recap still
/// describes the whole conversation, and greater means the session has moved
/// since — counted, never timed, because a session can sit untouched for a week
/// and a recap of it stays exactly as true as the day it was written.
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
