import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_git/repositories.dart';
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

/// **The prior**: whether this agent's adapter says a chat view is built from
/// its transcripts. No longer the answer — [SessionChatView] is the
/// per-session reading a surface asks. An agent spoken to over ACP has one
/// without a transcript file: the server keeps its conversation as rows.
bool agentSupportsChatView(AgentAdapter? adapter) =>
    adapter != null &&
    (adapter.acp != null || (adapter.transcripts?.buildsChatView ?? false));

/// The default view for an agent: chat where we can build one, terminal
/// otherwise. The user can always switch.
SessionView defaultViewFor(AgentAdapter? adapter) =>
    agentSupportsChatView(adapter) ? SessionView.chat : SessionView.terminal;

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
    this.titleTyped = false,
    this.surface = SessionSurface.pane,
    this.useWorktree = false,
    this.worktreeBranch,
    this.worktreeBase,
    this.worktreeExistingBranch,
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
    this.targetPaneId,
    this.openTab = true,
  });

  final Repository repository;
  final AgentInstallation installation;
  final String title;

  /// Whether a person typed [title] — the New-session dialog, a phone's
  /// start. Recorded on the row as theirs (`newSessionTitle`), so an agent's
  /// own name for the conversation never replaces it; blank or a placeholder
  /// still leaves the naming to the agent.
  final bool titleTyped;

  /// New or existing — the *only* input to permission-mode resolution.
  final SessionPurpose purpose;

  final SessionSurface surface;

  /// Create a **new** worktree for this session.
  final bool useWorktree;

  /// With [useWorktree]: the branch the new worktree creates, or null for
  /// the session-named one a caller that did not ask gets.
  final String? worktreeBranch;

  /// With [useWorktree]: what [worktreeBranch] starts from; null is HEAD.
  final String? worktreeBase;

  /// With [useWorktree]: a branch that already exists — local, or
  /// remote-tracking — for the new worktree to check out, rather than creating
  /// [worktreeBranch] from [worktreeBase]. Refused when another worktree has
  /// it checked out: that one is joined through [existingWorktree] instead.
  final String? worktreeExistingBranch;

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

  /// An empty terminal region this in-app launch should occupy. Null, stale or
  /// already filled fall back to a new tab rather than failing the launch.
  final String? targetPaneId;

  /// Whether this window shows what started. False keeps the person where
  /// they are: the server runs the session and no tab opens or takes focus.
  /// An external surface still opens its terminal window, which is the ask.
  final bool openTab;

  /// The same request against a re-read [installation]. The launch-time path
  /// check hands back the row a repair moved, and the spawn must use that one.
  SessionLaunchRequest withInstallation(AgentInstallation installation) =>
      _copy(installation: installation);

  /// The same request resuming [conversationId] instead — a row whose recorded
  /// conversation was never written, continuing the one it started on.
  SessionLaunchRequest withResumeExternalSessionId(String conversationId) =>
      _copy(resumeExternalSessionId: conversationId);

  SessionLaunchRequest _copy({
    AgentInstallation? installation,
    String? resumeExternalSessionId,
  }) => SessionLaunchRequest(
    repository: repository,
    installation: installation ?? this.installation,
    title: title,
    purpose: purpose,
    titleTyped: titleTyped,
    surface: surface,
    useWorktree: useWorktree,
    worktreeBranch: worktreeBranch,
    worktreeBase: worktreeBase,
    worktreeExistingBranch: worktreeExistingBranch,
    existingWorktree: existingWorktree,
    workingDirectory: workingDirectory,
    additionalRepositories: additionalRepositories,
    resumeExternalSessionId:
        resumeExternalSessionId ?? this.resumeExternalSessionId,
    restartSessionId: restartSessionId,
    firstMessage: firstMessage,
    systemPromptFile: systemPromptFile,
    parentSessionId: parentSessionId,
    parentLink: parentLink,
    forkExternalSessionId: forkExternalSessionId,
    permissionOverride: permissionOverride,
    modelOverride: modelOverride,
    view: view,
    targetPaneId: targetPaneId,
    openTab: openTab,
  );
}

/// The plain words for a launch whose agent executable no longer opens: which
/// agent, the path that failed, and the one lever that corrects it.
///
/// Two sentences and not one, because "nothing is there" and "there but out of
/// reach" call for opposite actions (CLAUDE.md §20).
String agentExecutableRefusal({
  required String agentName,
  required String path,
  required ExecutableReachability reachability,
}) => reachability == ExecutableReachability.unreachable
    ? '$agentName cannot be started: $path leads through a link this machine '
          'will not follow, and looking again just now did not resolve it. '
          'Set the path the executable is actually at in '
          'Settings → Agents and accounts → Executables.'
    : '$agentName cannot be started: nothing opens at $path, and looking '
          'again just now did not find it anywhere else. Install the CLI, or '
          'set the path yourself in Settings → Agents and accounts → '
          'Executables.';
