import '../../terminal/application/terminal_sessions_controller.dart';
import '../../terminal/domain/terminal_profile.dart';
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

  /// The shell this pane runs, or null when it could not be determined — a
  /// pane restored from a profile id this build no longer resolves. Null is
  /// offered only the untagged snippets, which is the same rule
  /// [CommandSnippet.fitsShell] applies from the other side: neither party
  /// guesses.
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

/// **The active terminal**, resolved the one way that survives a modal.
///
/// Not `FocusManager.primaryFocus`: the palette is a dialog, so by the time an
/// item is picked the keyboard is in a search field and the pane has lost focus
/// entirely. What "active" means in this app is controller state —
/// `activeTab.focusedPaneId`, moved when the user clicks a pane, activates a
/// tab or walks the splits — and a dialog does not touch it. So the pane that
/// was in front when the palette opened is still the answer when it closes,
/// which is exactly what the toolbar's own find and split buttons act on.
///
/// Callers resolve this **when the palette is built**, not when a row is
/// activated, and hand the captured target down. The two answers agree in every
/// ordinary case; where they differ — the pane's process exits under the open
/// palette and the controller refocuses another — the captured one is right and
/// a fresh read would type into a pane the user never chose. The staleness is
/// caught rather than ignored: [insertSnippet] re-reads the pane before writing
/// and reports [SnippetOutcome.noPane] if it has gone.
///
/// Returns null when the active region is empty (a split nobody has filled) or
/// when there is no tab at all.
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
    shell: terminalProfileFromId(instance.profileId)?.shell,
    isAgentPane: instance.agentLaunch != null,
    live: state.livenessOf(paneId).isLive,
  );
}

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

/// Types [snippet] into a pane.
///
/// ## Type, do not send
///
/// The default is to write the command at the prompt and stop. `sendTo` and
/// `TerminalControlTools._type` both append a carriage return because a PTY
/// line discipline reads CR as *submit*, and both are delivering something the
/// caller composed on purpose in that moment. A snippet is the opposite: it was
/// written weeks ago, it is picked from a fuzzy-matched list where the row
/// above is one arrow key away, and the library is exactly where the
/// irreversible one-liners live. So the carriage return is opt-in, per snippet,
/// declared once by the person who saved it — never a modifier held at pick
/// time, which is a thing fingers do by accident.
///
/// This is the third member of the same family as those two, not a second write
/// path beside them: it reaches the pane through `Terminal.textInput` exactly
/// as they do, and the only difference is whether the CR is appended — the same
/// distinction `SessionLauncher.answerPrompt` already draws against `sendTo`.
///
/// ## Never into a live agent turn
///
/// A pane running an agent CLI is somebody's session, and a carriage return
/// there is a *turn taken as if the user had typed it* — the reason
/// `terminal_run` refuses such a pane outright. Typing is still allowed and
/// still useful (it is how a command gets in front of the agent's composer for
/// the user to finish), but [CommandSnippet.submit] is ignored there and the
/// result says so.
///
/// ## Placeholders, and why there are none yet
///
/// A `${...}` marker would need a fill-in step before the text is typed, an
/// escape for a literal `$`, and a decision about whether the caret lands mid
/// string — which is a surface of its own, not a field. It is also less needed
/// than it looks *because* this types rather than sends: a snippet saved as
/// `git checkout ` lands at the prompt with the caret after it, and the branch
/// name is simply the next thing the user types. Trailing arguments are free
/// today; only interior ones would need the language, and they can have their
/// own pass.
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
