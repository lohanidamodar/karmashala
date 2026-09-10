import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_git/repositories.dart';
import '../../terminal/data/system_terminal_service.dart';
import 'session_lineage.dart';

/// Where a session's process actually lives — a **runtime** distinction, not a
/// rendering one: `pane` means we own the process, `external` means somebody
/// else's terminal window does. How it is *drawn* is [SessionView].
enum SessionSurface {
  /// A PTY pane inside the app. Every in-app agent session runs here.
  pane,

  /// A terminal emulator we launched and do not own.
  external,
}

/// How an in-app session is rendered. A view, never a second kind of session:
/// same record, same PTY, same lifecycle. Switching starts and stops nothing.
enum SessionView {
  /// Structured chat, reconstructed from the agent's own transcript.
  chat,

  /// The terminal the agent is actually running in.
  terminal;

  SessionView get other => this == chat ? terminal : chat;
}

/// **The prior**: whether this agent's store *format* is one we read, before
/// anybody has looked at a particular session.
///
/// **It is no longer the answer, and must not be used as one.** Antigravity's
/// own JSONL transcripts exist for every conversation on the WSL install here
/// and for none on the Windows one, so a per-format verdict is wrong in one
/// direction or the other. What a surface asks is [SessionChatView], the
/// per-session reading; this is the prior it carries until something has been
/// looked at, and [defaultViewFor] — choosing an opening view before a session
/// exists — is the other honest use.
bool agentSupportsChatView(AgentDescriptor? descriptor) {
  final format = descriptor?.store?.format;
  return format == AgentStoreFormat.claudeJsonl ||
      format == AgentStoreFormat.codexRollout;
}

/// The default view for an agent: chat where we can build one, terminal
/// otherwise. The user can always switch.
SessionView defaultViewFor(AgentDescriptor? descriptor) =>
    agentSupportsChatView(descriptor) ? SessionView.chat : SessionView.terminal;

/// Why a permission mode is being resolved. Callers say what they are doing and
/// exactly one place turns that into a selection — the fix for permission mode
/// being resolved in eight places with three different answers.
enum SessionPurpose {
  /// A conversation that does not exist yet, whatever it is seeded with.
  newSession,

  /// Continuing a conversation the agent already has a record of.
  existingSession,
}

/// Everything one session-creation entry point has to decide, stated once, so
/// the per-call-site divergence has somewhere to have been removed *to*.
class SessionLaunchRequest {
  const SessionLaunchRequest({
    required this.repository,
    required this.installation,
    required this.title,
    required this.purpose,
    this.surface = SessionSurface.pane,
    this.useWorktree = false,
    this.existingWorktree,
    this.workingDirectory,
    this.additionalRepositories = const [],
    this.resumeExternalSessionId,
    this.restartSessionId,
    this.firstMessage,
    this.systemPromptFile,
    this.parentSessionId,
    this.parentLink,
    this.forkExternalSessionId,
    this.permissionOverride,
    this.modelOverride,
    this.view,
    this.externalTerminal,
    this.targetPaneId,
  });

  final Repository repository;
  final AgentInstallation installation;
  final String title;

  /// New or existing — the *only* input to permission-mode resolution.
  final SessionPurpose purpose;

  final SessionSurface surface;

  /// Create a **new** worktree for this session.
  final bool useWorktree;

  /// Run in a worktree that already exists, rather than creating one — what a
  /// handoff continuing on the same branch needs. [useWorktree] means *create
  /// one*, and leaving it false put the new session in the repository root, on
  /// a different branch from the work being handed over. Mutually exclusive
  /// with it; the launcher refuses both.
  final EnvironmentPath? existingWorktree;

  /// Run in this directory rather than the repository root, without claiming it
  /// is a worktree — what a handoff, a fork and a resume of an adopted session
  /// all need.
  ///
  /// It does *not* also protect the conversation: neither Codex nor Claude Code
  /// keys its store strictly by cwd. That claim now lives per agent, with its
  /// evidence, on [AgentResumeLocality]. [existingWorktree] wins when both are
  /// set, being the stronger statement about the same place.
  final EnvironmentPath? workingDirectory;

  final List<Repository> additionalRepositories;

  /// The CLI's own session id to resume, when continuing one it already wrote.
  final String? resumeExternalSessionId;

  /// A workspace row to **start a fresh conversation in**, keeping the row.
  ///
  /// The other end of `SessionConversationMissing`: a row whose promised
  /// conversation id the CLI never wrote refuses every resume, and starting
  /// over elsewhere throws away that row's title, age and place in a lineage.
  /// Deliberately **not** a resume — there is nothing to resume — so
  /// [resumeExternalSessionId] must be null and the launcher refuses both.
  ///
  /// Ignored when it names no reusable row (archived, another repository or
  /// installation, or one a pane of ours is running), falling back to create.
  final String? restartSessionId;

  /// Sent as soon as the session is up. One code path, guarded once.
  final String? firstMessage;

  /// Extra system prompt for this session, as **text** — the handoff packet's
  /// way in for a CLI that takes a file of one. Text and not a path because the
  /// file is named by the session it belongs to, which only
  /// [SessionLauncher.launch] knows; an agent with no such flag, an environment
  /// with no name for the path and a failed write all fall back to the prompt.
  final String? systemPromptFile;

  /// The session this one came from, when it came from one. Never supplied by
  /// the model directly — see `SessionDepth`.
  final String? parentSessionId;

  /// Why [parentSessionId] is set. Null is read as [SessionLink.spawn] by the
  /// launcher when a parent is named without one, which keeps the MCP spawn
  /// path — the only caller that predates this field — meaning what it did.
  final SessionLink? parentLink;

  /// The CLI's own id for a conversation to **fork**, when the agent forks
  /// natively. Separate from [resumeExternalSessionId] because the two produce
  /// different command lines and must never both be honoured — continuing and
  /// branching one conversation at once is not a thing.
  final String? forkExternalSessionId;

  /// Escape hatch for a caller that genuinely knows better than the setting.
  /// Unused by any in-app path; kept so "the setting decides" stays true by
  /// inspection rather than by convention.
  final PermissionSelection? permissionOverride;

  /// The model this launch should record and run under, or null to leave the
  /// session's own choice — and, failing that, the default — alone. Null does
  /// not mean "no model", it means "this caller is not deciding"; a resolved
  /// value here would overwrite the choice the model chip made.
  final String? modelOverride;

  /// Forced rendering, or `null` to take the agent's default.
  final SessionView? view;

  /// Which external terminal to launch into, for [SessionSurface.external].
  /// `null` takes the configured default, which is what every in-app caller
  /// should do — the parameter exists for the dialog, where the user picked one.
  final SystemTerminal? externalTerminal;

  /// An empty terminal region this in-app launch should occupy. Null, stale or
  /// already filled all fall back to a new workbench tab: the session must not
  /// fail merely because its destination disappeared while a dialog was open.
  /// External launches ignore it — their process has no in-app pane.
  final String? targetPaneId;
}
