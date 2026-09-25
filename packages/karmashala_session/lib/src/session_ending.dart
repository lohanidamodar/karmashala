import 'package:agent_cli/descriptors.dart';
import 'session_status.dart';

/// How a session stopped — **not one event**, and the difference is the whole
/// feature. Five values: losing sight of a session is its own state.
enum SessionEnding {
  /// The agent's own run ended without an error.
  completed,

  /// The agent stopped in error, or its launch never got off the ground.
  failed,

  /// The user stopped it.
  cancelled,

  /// The work moved to another session — a handoff or a fork.
  handedOff,

  /// Nothing can tell us what this session is doing any more. Deliberately
  /// **not** an ending, and named so a `switch` says that out loud.
  lostTrack,

  /// An ending this build does not know. Never written, only read: a wrong word
  /// over a real ending is worse than admitting it could not be read.
  unrecognised;

  /// Plain words for a reader.
  String get label => switch (this) {
    SessionEnding.completed => 'finished',
    SessionEnding.failed => 'stopped in error',
    SessionEnding.cancelled => 'was stopped by you',
    SessionEnding.handedOff => 'was handed on',
    SessionEnding.lostTrack => 'went out of sight',
    SessionEnding.unrecognised => 'ended in a way this build cannot describe',
  };

  static SessionEnding fromName(String? name) => values.firstWhere(
    (ending) => ending.name == name,
    orElse: () => SessionEnding.unrecognised,
  );
}

/// The ending a session's own row claims, or null while it is still live. Note
/// `unknown` is *not* an ending: a restart turns every `running` row into it.
SessionEnding? endingOfStatus(SessionStatus status) => switch (status) {
  SessionStatus.completed => SessionEnding.completed,
  SessionStatus.failed => SessionEnding.failed,
  SessionStatus.cancelled => SessionEnding.cancelled,
  SessionStatus.created ||
  SessionStatus.running ||
  SessionStatus.idle ||
  SessionStatus.unknown => null,
};

/// The ending an observed status change amounts to, deliberately almost always
/// null: a first observation is not a change, and a turn ending is not one.
SessionEnding? endingOfTransition({
  required AgentActivityStatus? from,
  required AgentActivityStatus to,
}) {
  if (from == null || from == to) return null;
  return switch (to) {
    AgentActivityStatus.failed => SessionEnding.failed,
    AgentActivityStatus.unknown => SessionEnding.lostTrack,
    AgentActivityStatus.idle ||
    AgentActivityStatus.working ||
    AgentActivityStatus.awaitingApproval => null,
  };
}

/// The ending a pane's own process exit amounts to, for a session without host
/// facts. Only exit **0**: a non-zero code cannot tell a crash from a Ctrl-C
/// from a wrapper that fell over, and `failed` already arrives.
SessionEnding? endingOfPaneExit(int? exitCode) =>
    exitCode == 0 ? SessionEnding.completed : null;
