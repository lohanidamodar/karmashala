import 'agent_rewind_points.dart';

/// **What an agent's own undo offers beside Karmashala's checkpoints.**
/// Read-only: restoring through it belongs to the agent, in its pane.
sealed class AgentRewind {
  const AgentRewind();

  /// Nothing is known about this agent's undo, so nothing is said.
  const factory AgentRewind.unknown() = UnknownRewind;
}

/// Nothing is known about the agent's own undo.
final class UnknownRewind extends AgentRewind {
  const UnknownRewind();
}

/// The agent keeps rewind points of its own, readable from its transcript.
final class OwnRewindPoints extends AgentRewind {
  const OwnRewindPoints({
    required this.lineMarker,
    required this.parse,
    required this.note,
  });

  /// A substring every line recording a rewind point contains, so a reader
  /// can skip the rest of a large transcript without decoding it.
  final String lineMarker;

  /// The rewind points in the transcript lines that carry [lineMarker].
  final AgentRewindPoints Function(Iterable<String> lines) parse;

  /// What to say under the checkpoint list, with the points when they could
  /// be read and null when they could not.
  final String Function(AgentRewindPoints? points) note;
}

/// The agent has no undo of its own; the checkpoints are the way back.
final class NoOwnUndo extends AgentRewind {
  const NoOwnUndo(this.note);

  final String note;
}
