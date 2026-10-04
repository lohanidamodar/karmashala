import 'package:agent_cli/descriptors.dart';

/// The bound a `session_wait` caller that names none gets.
const Duration kSessionWaitDefaultBound = Duration(seconds: 30);

/// The most a caller may ask for. Two 60-second walls sit between a tool call
/// and its answer — the local RPC timeout, and an MCP client that re-sends.
const Duration kSessionWaitMaxBound = Duration(seconds: 45);

/// The bound for a caller's `timeoutSeconds`, clamped rather than refused:
/// `timeout` with the session still running is true whichever bound applied.
Duration sessionWaitBoundFor(num? seconds) {
  if (seconds == null) return kSessionWaitDefaultBound;
  final rounded = seconds.round();
  if (rounded <= 0) return kSessionWaitDefaultBound;
  final asked = Duration(seconds: rounded);
  return asked > kSessionWaitMaxBound ? kSessionWaitMaxBound : asked;
}

/// What a wait ended on. [done] is idle-and-seen-changed; [idle] is equally
/// true of a session that never started, which is why they are two states.
enum SessionWaitState {
  /// Ready for input, and nothing moved while we watched.
  idle,

  /// Ready for input, and the session's evidence moved during the wait.
  done,

  /// Stopped for a person: an approval prompt, or a question in the inbox.
  blocked,

  /// The pane or the session is over.
  ended,

  /// The caller's bound was reached. The session is still running.
  timeout,
}

/// What a session is blocked on, in the source's own words.
class SessionBlock {
  const SessionBlock({required this.kind, this.text, this.options = const []});

  /// `approvalPrompt` for a modal on screen, otherwise the inbox item's kind.
  final String kind;

  /// The agent's own words, or null when the source gave none. Never
  /// synthesised — an absent line reads as "not recorded".
  final String? text;

  /// The answers an ACP agent offered its approval, each one `session_answer`
  /// can choose by id; empty for any other prompt.
  final List<AgentToolAskOption> options;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'text': text,
    if (options.isNotEmpty) 'options': [for (final o in options) o.toJson()],
  };
}

/// One wait's answer.
class SessionWaitOutcome {
  const SessionWaitOutcome({
    required this.state,
    required this.agentStatus,
    required this.source,
    required this.changed,
    this.since,
    this.evidenceAge,
    this.transcriptChanged,
    this.blockedOn,
    this.exitCode,
    this.exitCodeKnown = false,
    this.inputSent,
  });

  final SessionWaitState state;

  /// The status word behind [state], so a turn that ended in `failed` is not
  /// flattened into "done" with the reason dropped.
  final AgentActivityStatus agentStatus;

  final AgentStatusSource source;

  /// When the evidence behind this answer was **produced** — never when we
  /// looked. Null when no source could tell us anything.
  final DateTime? since;

  /// How old that evidence was at the moment of the answer.
  final Duration? evidenceAge;

  /// Whether the session's evidence moved during the wait. The one thing that
  /// separates [SessionWaitState.done] from [SessionWaitState.idle].
  final bool changed;

  /// Whether the conversation moved, or null when no source could tell.
  final bool? transcriptChanged;

  final SessionBlock? blockedOn;

  final int? exitCode;

  /// Whether [exitCode] was learned. A missing code is never a zero.
  final bool exitCodeKnown;

  /// Whether this call sent input before waiting. Null when it sent none.
  final bool? inputSent;
}


/// One wait's answer. Every absence is spelled as an absence: `exitCode` is
/// null with `exitCodeKnown: false` rather than a zero.
Map<String, Object?> renderWaitOutcome(SessionWaitOutcome outcome) =>
    <String, Object?>{
      'state': outcome.state.name,
      // So a turn that ended in an error is not flattened into "ready for
      // input" with the reason dropped.
      'agentStatus': outcome.agentStatus.name,
      'evidenceSource': outcome.source.name,
      'since': outcome.since?.toIso8601String(),
      'evidenceAgeSeconds': outcome.evidenceAge?.inSeconds,
      'changed': outcome.changed,
      'transcriptChanged': outcome.transcriptChanged,
      'transcriptChangedSource': outcome.transcriptChanged == null
          ? 'not recorded — this session\'s status carries no transcript '
                'position, so whether it said anything is unknown'
          : 'the transcript this session\'s status is read from',
      'blockedOn': outcome.blockedOn?.toJson(),
      'exitCode': outcome.exitCode,
      'exitCodeKnown': outcome.exitCodeKnown,
      'inputSent': outcome.inputSent,
      'note': waitOutcomeNote(outcome),
    };

/// The sentence a model reads before deciding what to do next: `idle` is also
/// the shape of a session that never started, `timeout` only this call's bound.
String waitOutcomeNote(SessionWaitOutcome outcome) => switch (outcome.state) {
  SessionWaitState.idle =>
    'Ready for input, and nothing moved while this call watched. That is '
        'not proof it did anything: a session that never started reads '
        'exactly like one that finished before you asked. "done" is the '
        'state that means it moved.',
  SessionWaitState.done =>
    'Ready for input, and its evidence moved while this call watched — it '
        'finished something. What it finished is in session_transcript; '
        'this says only that it stopped.',
  SessionWaitState.blocked =>
    'BLOCKED ON A PERSON. This session has stopped for an approval or a '
        'question and will not move until somebody answers it — waiting '
        'longer will not change that. Anything you send now lands in that '
        'prompt as a keystroke rather than arriving as a message. Read '
        'what is being asked with session_transcript and answer it with '
        'session_answer, or leave it for the user.',
  SessionWaitState.ended =>
    'The pane behind this session is gone. session_transcript still reads '
        'its record, and open_session will resume it. '
        '${outcome.exitCodeKnown ? 'It exited with ${outcome.exitCode}.' : 'Its exit code is UNKNOWN — not 0; nothing told us what it exited with.'}',
  SessionWaitState.timeout =>
    'TIMEOUT — this is your bound, not a verdict about the session. It is '
        'STILL RUNNING and may finish a moment from now. '
        '${outcome.inputSent ?? false ? 'YOUR MESSAGE WAS ALREADY DELIVERED (inputSent: true): a timeout does not prove nothing was sent, so do not send it again' : 'This call sent nothing (inputSent is null)'}'
        '. Read the session with session_transcript, or call session_wait '
        'to go on waiting.',
};

