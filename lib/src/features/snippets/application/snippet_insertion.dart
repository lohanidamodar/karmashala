import '../../terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import '../domain/command_snippet.dart';

/// The pane a snippet would go into, and everything that decides what happens
/// when it gets there.
class SnippetTarget {
  const SnippetTarget({
    required this.paneId,
    required this.title,
    required this.shell,
    required this.isAgentPane,
    required this.live,
  });

  final String paneId;
  final String title;

  /// The shell this pane runs, or null when it could not be determined. Null is
  /// offered only the untagged snippets — neither party guesses.
  final TerminalShell? shell;

  /// Whether this pane is somebody's live agent CLI rather than a shell.
  final bool isAgentPane;

  /// Whether a process is still behind it.
  final bool live;

  /// The shell's name as a snippet tags it.
  String? get shellId => shell?.name;

  /// The snippets that belong in this pane.
  List<CommandSnippet> filter(List<CommandSnippet> snippets) => [
    for (final snippet in snippets)
      if (snippet.fitsShell(shellId)) snippet,
  ];
}

/// **The active terminal**, resolved from controller state rather than
/// `primaryFocus`: the palette is a dialog and the pane has lost focus by then.
SnippetTarget? resolveSnippetTarget(
  TerminalSessionsController terminals,
  TerminalSessionsState state,
) {
  final tab = state.activeTab;
  if (tab == null) return null;
  return snippetTargetFor(terminals, state, tab.focusedPaneId);
}

/// [resolveSnippetTarget] for a named pane — what the MCP tool uses when a
/// caller passes a `paneId` of its own.
SnippetTarget? snippetTargetFor(
  TerminalSessionsController terminals,
  TerminalSessionsState state,
  String paneId,
) {
  final instance = terminals.instanceFor(paneId);
  if (instance == null) return null;
  return SnippetTarget(
    paneId: paneId,
    title: instance.title,
    // An agent pane's id is `agent:claudeCode`, which resolves to no profile and
    // so read as unknown. The launch says which distribution it is in.
    shell:
        terminalProfileFromId(instance.profileId)?.shell ??
        _shellOfLaunch(instance.agentLaunch),
    isAgentPane: instance.agentLaunch != null,
    live: state.livenessOf(paneId).isLive,
  );
}

/// The shell an agent's launch *states*, or null. Only the WSL case is
/// inferred: a native agent runs no shell and an SSH one names a host.
TerminalShell? _shellOfLaunch(AgentPaneLaunch? launch) =>
    launch?.wslDistribution == null ? null : TerminalShell.wsl;

/// What happened when a snippet was handed to a pane.
enum SnippetOutcome {
  /// Typed at the prompt and left there for the user to read and press Enter
  /// on. The ordinary answer.
  typed,

  /// Typed and submitted, because the snippet says so.
  submitted,

  /// Typed, and deliberately *not* submitted: the pane is running an agent
  /// CLI, where a carriage return takes a turn in somebody's live session.
  typedIntoAgentPane,

  /// There is no such pane — the active region is empty, or the pane closed
  /// while the picker was open.
  noPane,

  /// The pane is there but its process has exited; there is nothing to type
  /// into.
  paneNotLive,
}

/// The result of [insertSnippet]: what happened, where, and what to tell the
/// user when it is worth saying anything.
class SnippetInsertionResult {
  const SnippetInsertionResult(this.outcome, {this.paneId, this.message});

  final SnippetOutcome outcome;
  final String? paneId;

  /// Null when nothing needs saying — a snippet typed into the pane the user
  /// is looking at is its own feedback.
  final String? message;

  bool get delivered =>
      outcome == SnippetOutcome.typed ||
      outcome == SnippetOutcome.submitted ||
      outcome == SnippetOutcome.typedIntoAgentPane;
}

/// Types [snippet] into a pane. **Type, do not send** — the carriage return is
/// opt-in per snippet, and is ignored outright in a live agent turn.
SnippetInsertionResult insertSnippet({
  required TerminalSessionsController terminals,
  required TerminalSessionsState state,
  required CommandSnippet snippet,
  required String paneId,
}) {
  final instance = terminals.instanceFor(paneId);
  if (instance == null) {
    return const SnippetInsertionResult(
      SnippetOutcome.noPane,
      message: 'That terminal is no longer open.',
    );
  }
  if (!state.livenessOf(paneId).isLive) {
    return SnippetInsertionResult(
      SnippetOutcome.paneNotLive,
      paneId: paneId,
      message: 'That terminal\'s process has exited; there is nothing to type '
          'into.',
    );
  }

  final command = singleLine(snippet.command);
  if (command.isEmpty) {
    return SnippetInsertionResult(
      SnippetOutcome.noPane,
      paneId: paneId,
      message: 'That snippet is empty.',
    );
  }

  instance.terminal.textInput(command);

  final agent = instance.agentLaunch;
  if (agent != null) {
    return SnippetInsertionResult(
      SnippetOutcome.typedIntoAgentPane,
      paneId: paneId,
      message: snippet.submit
          ? 'Typed into the ${agent.agentId} session without sending it — '
                'pressing Enter there takes a turn in a live conversation.'
          : null,
    );
  }
  if (!snippet.submit) {
    return SnippetInsertionResult(SnippetOutcome.typed, paneId: paneId);
  }
  // A carriage return, not a newline, for the reason `SessionLauncher.sendTo`
  // gives: a PTY line discipline reads CR as "submit" and leaves a bare LF
  // sitting on the line.
  instance.terminal.textInput('\r');
  return SnippetInsertionResult(SnippetOutcome.submitted, paneId: paneId);
}
