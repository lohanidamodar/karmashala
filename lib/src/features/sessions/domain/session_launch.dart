import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_git/repositories.dart';
import '../../terminal/data/system_terminal_service.dart';
import 'session_lineage.dart';

/// Where a session's process actually lives — a **runtime** distinction: how it
/// is *drawn* is [SessionView].
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

/// **The prior**: whether this agent's store *format* is one we read. No longer
/// the answer — [SessionChatView] is the per-session reading a surface asks.
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
/// exactly one place turns that into a selection.
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

  /// Run in a worktree that already exists rather than creating one — what a
  /// handoff on the same branch needs. Mutually exclusive with [useWorktree].
  final EnvironmentPath? existingWorktree;

  /// Run in this directory without claiming it is a worktree. It does *not*
  /// also find the conversation — that claim lives on [AgentResumeLocality].
  final EnvironmentPath? workingDirectory;

  final List<Repository> additionalRepositories;

  /// The CLI's own session id to resume, when continuing one it already wrote.
  final String? resumeExternalSessionId;

  /// A workspace row to **start a fresh conversation in**, keeping the row.
  /// Not a resume — there is nothing to resume — so the launcher refuses both.
  final String? restartSessionId;

  /// Sent as soon as the session is up. One code path, guarded once.
  final String? firstMessage;

  /// Extra system prompt as **text**, not a path: the file is named by the
  /// session it belongs to, which only [SessionLauncher.launch] knows.
  final String? systemPromptFile;

  /// The session this one came from, when it came from one. Never supplied by
  /// the model directly — see `SessionDepth`.
  final String? parentSessionId;

  /// Why [parentSessionId] is set. Null reads as [SessionLink.spawn], which
  /// keeps the MCP path — the only caller predating this — meaning what it did.
  final SessionLink? parentLink;

  /// The CLI's own id for a conversation to **fork**. Separate from
  /// [resumeExternalSessionId]: the two must never both be honoured.
  final String? forkExternalSessionId;

  /// Escape hatch for a caller that genuinely knows better than the setting.
  /// Unused in-app, so "the setting decides" stays true by inspection.
  final PermissionSelection? permissionOverride;

  /// The model this launch records and runs under, or null to leave the
  /// session's own choice alone. Null is "not deciding", never "no model".
  final String? modelOverride;

  /// Forced rendering, or `null` to take the agent's default.
  final SessionView? view;

  /// Which external terminal to launch into, for [SessionSurface.external].
  /// `null` takes the configured default; the parameter exists for the dialog.
  final SystemTerminal? externalTerminal;

  /// An empty terminal region this in-app launch should occupy. Null, stale or
  /// already filled fall back to a new tab rather than failing the launch.
  final String? targetPaneId;
}
