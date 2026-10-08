part of '../typed_command.dart';

// What a parsed command suggests, previews and runs.

/// What running a command does. Each maps onto an existing app action.
sealed class CommandAction {
  const CommandAction();
}

class StartCommand extends CommandAction {
  const StartCommand({
    required this.projectId,
    required this.installationId,
    this.worktree = false,
    this.firstMessage,
    this.keepHere = false,
  });

  /// Null starts it with no project, in a scratch folder on the agent's machine.
  final String? projectId;
  final String installationId;
  final bool worktree;
  final String? firstMessage;

  /// Started at the server with no tab, and peeked on the Agent dashboard.
  final bool keepHere;
}

/// The New-session dialog, opened on what was typed instead of starting.
class OpenNewSessionDialogCommand extends CommandAction {
  const OpenNewSessionDialogCommand({this.projectId, this.firstMessage});

  final String? projectId;
  final String? firstMessage;
}

class ResumeCommand extends CommandAction {
  const ResumeCommand({required this.sessionId, this.imported = false});

  final String sessionId;
  final bool imported;
}

class OpenTerminalCommand extends CommandAction {
  const OpenTerminalCommand({
    required this.projectId,
    required this.environmentId,
    required this.profileId,
    required this.workingDirectory,
  });

  final String projectId;
  final String environmentId;
  final String profileId;
  final String workingDirectory;
}

class AnswerCommand extends CommandAction {
  const AnswerCommand({required this.itemId});

  final String itemId;
}

class StopCommand extends CommandAction {
  const StopCommand(this.sessionId);

  final String sessionId;
}

class ForkCommand extends CommandAction {
  const ForkCommand(this.sessionId);

  final String sessionId;
}

class EndCommand extends CommandAction {
  const EndCommand(this.sessionId);

  final String sessionId;
}

/// Picks option [option] (0-based) of the question [toolUseId] opened.
class AnswerQuestionCommand extends CommandAction {
  const AnswerQuestionCommand({
    required this.sessionId,
    required this.toolUseId,
    required this.option,
  });

  final String sessionId;
  final String toolUseId;
  final int option;
}

/// Allows or denies the command approval [sessionId] waits on.
class ApprovalCommand extends CommandAction {
  const ApprovalCommand(this.sessionId, {required this.allow});

  final String sessionId;
  final bool allow;
}

/// Says [text] to every one of [sessionIds], through the dashboard's send.
class MessageCommand extends CommandAction {
  const MessageCommand(this.sessionIds, this.text);

  final List<String> sessionIds;
  final String text;
}

/// Interrupts each of [sessionIds], as [StopCommand] does one.
class StopAllCommand extends CommandAction {
  const StopAllCommand(this.sessionIds);

  final List<String> sessionIds;
}

/// Brings [sessionId] back at the server, with [message] as its next turn.
class BackgroundResumeCommand extends CommandAction {
  const BackgroundResumeCommand(this.sessionId, {this.message});

  final String sessionId;
  final String? message;
}

class ArchiveCommand extends CommandAction {
  const ArchiveCommand(this.sessionId);

  final String sessionId;
}

/// Peeks [sessionId] on the Agent dashboard.
class PeekCommand extends CommandAction {
  const PeekCommand(this.sessionId);

  final String sessionId;
}

/// What a command touching several sessions asks before it runs.
class CommandConfirm {
  const CommandConfirm({
    required this.title,
    required this.names,
    required this.confirmLabel,
  });

  final String title;

  /// Each session it acts on, by name.
  final List<String> names;
  final String confirmLabel;
}

/// A command with every required argument: what it would do, and why not.
class CommandPlan {
  const CommandPlan({
    required this.preview,
    required this.canonical,
    this.action,
    this.refusal,
    this.note,
    this.confirm,
  });

  /// Asked, naming the sessions, before a group command runs.
  final CommandConfirm? confirm;

  /// One line, before anything runs: `Start Codex in api · WSL archlinux`.
  final String preview;

  /// The line under [preview] when nothing is refused.
  final String? note;

  /// The fully resolved text, for history — the default agent spelled out.
  final String canonical;

  /// Null only when refused.
  final CommandAction? action;
  final String? refusal;

  bool get runnable => refusal == null && action != null;
}

/// One completion for the argument being typed.
class CommandSuggestion {
  const CommandSuggestion({
    required this.id,
    required this.kind,
    required this.label,
    required this.completion,
    this.hint,
    this.detail,
    this.disabledReason,
    this.dot,
  });

  final String id;
  final CommandArgKind kind;
  final String label;

  /// The whole box after accepting it, ending in a space so the next argument
  /// can be typed at once.
  final String completion;
  final String? hint;
  final String? detail;

  /// Shown rather than hidden: an entry that cannot be used says why.
  final String? disabledReason;
  final SessionDot? dot;

  bool get enabled => disabledReason == null;
}

/// The parse of a typed command.
class TypedCommand {
  const TypedCommand({
    required this.verb,
    this.pending,
    this.suggestions = const [],
    this.plan,
    this.error,
    this.launches = const [],
  });

  final CommandVerb verb;

  /// The argument the suggestions complete, or null when nothing is left.
  final CommandArgKind? pending;
  final List<CommandSuggestion> suggestions;
  final CommandPlan? plan;

  /// `start`'s ready-to-run sessions, each Enter away, best first; the last
  /// opens the dialog instead.
  final List<CommandPlan> launches;

  /// Something typed and committed that cannot be resolved.
  final String? error;
}

/// Suggestions shown for one argument.
const int kCommandSuggestionLimit = 12;
