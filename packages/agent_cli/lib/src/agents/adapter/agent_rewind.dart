import 'agent_rewind_points.dart';

/// **What an agent's own undo offers beside Karmashala's checkpoints.**
/// Its file restore belongs to the agent, in its pane; its conversation cut,
/// where declared, is driven from outside ([ConversationRewind]).
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
    this.conversation,
  });

  /// How its conversation can be cut back to before a message; null when it
  /// cannot be from outside its pane.
  final ConversationRewind? conversation;

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

/// What a rewind puts back: the files, the conversation, or both — the three
/// choices of Claude Code's own `/rewind`.
enum RewindMode {
  both('Code and conversation'),
  conversation('Conversation only'),
  code('Code only');

  const RewindMode(this.label);

  final String label;

  bool get restoresCode => this != conversation;
  bool get cutsConversation => this != code;

  static RewindMode? parse(Object? name) {
    for (final mode in values) {
      if (mode.name == name) return mode;
    }
    return null;
  }
}

/// A person's prompt on the conversation's live chain, as the agent's record
/// names it: [uuid] its own entry, [parentUuid] the entry it followed (null
/// for the first).
typedef ConversationPrompt = ({String uuid, String? parentUuid, String text});

/// **Cutting an agent's conversation back to before one of the person's
/// messages**, in each form it runs in.
final class ConversationRewind {
  const ConversationRewind({
    required this.promptsOf,
    required this.chatEvidence,
    required this.menu,
  });

  /// The person's prompts on the live chain of a record's [lines], oldest
  /// first; [leaf] names the entry the chain ends at, else the newest.
  final List<ConversationPrompt> Function(
    Iterable<String> lines, {
    String? leaf,
  })
  promptsOf;

  /// Where the chat form's cut (a resume that keeps the conversation only up
  /// to an entry) was read.
  final String chatEvidence;

  /// The terminal form's own rewind menu.
  final RewindMenu menu;
}

/// An agent's rewind menu in its terminal: [command] opens a list of the
/// person's messages, newest last; Enter on one opens the choices, whose
/// labels are [labels], and [cancel] closes it.
final class RewindMenu {
  const RewindMenu({
    required this.command,
    required this.listMarker,
    required this.labels,
    required this.cancel,
    required this.evidence,
  });

  final String command;

  /// Text the message list shows while it is open.
  final String listMarker;

  /// Each mode's choice, as the menu words it.
  final Map<RewindMode, String> labels;
  final String cancel;
  final String evidence;
}
