import '../../agents/domain/agent_descriptor.dart';
import '../../agents/domain/agent_installation.dart';
import '../../environments/domain/environment_path.dart';
import '../../repositories/domain/repository.dart';
import '../../settings/domain/permission_mode.dart';
import '../../terminal/data/system_terminal_service.dart';
import 'session_lineage.dart';

/// Where a session's process actually lives.
///
/// This is a **runtime** distinction, not a rendering one: `pane` means we own
/// the process, `external` means somebody else's terminal window does. How an
/// in-app session is *drawn* is [SessionView], which is orthogonal.
enum SessionSurface {
  /// A PTY pane inside the app. Every in-app agent session runs here.
  pane,

  /// A terminal emulator we launched and do not own.
  external,
}

/// How an in-app session is rendered. A view, never a second kind of session.
///
/// Both views are over the same session record, the same PTY and the same
/// lifecycle. Switching between them starts and stops nothing.
enum SessionView {
  /// Structured chat, reconstructed from the agent's own transcript.
  chat,

  /// The terminal the agent is actually running in.
  terminal;

  SessionView get other => this == chat ? terminal : chat;
}

/// Whether a chat view can be offered for an agent, and why not when it cannot.
///
/// This is a **capability query over the registry**, deliberately not a branch
/// on whether the agent has a hand-written protocol adapter. The runtime is the
/// same either way — a PTY — so an agent without a chat view is not a different
/// kind of session, it is the same session with one of its two renderings
/// unavailable.
///
/// The capability is "can we read this agent's own structured record of the
/// conversation", which is exactly what an [AgentStoreSpec] with a readable
/// [AgentStoreFormat] says. It is not "does an `AgentAdapter` subclass exist":
/// Antigravity has an adapter and no readable store, and correctly gets no chat
/// view.
bool agentSupportsChatView(AgentDescriptor? descriptor) {
  final format = descriptor?.store?.format;
  return format == AgentStoreFormat.claudeJsonl ||
      format == AgentStoreFormat.codexRollout;
}

/// The default view for an agent: chat where we can build one, terminal
/// otherwise. The user can always switch.
SessionView defaultViewFor(AgentDescriptor? descriptor) =>
    agentSupportsChatView(descriptor) ? SessionView.chat : SessionView.terminal;

/// Why a permission mode is being resolved.
///
/// Loop 33's audit found permission mode resolved in eight places with three
/// different answers — the sharpest being a *new* session started under the
/// "existing sessions" preference. This enum is the fix: callers say what they
/// are doing, and exactly one place turns that into a [PermissionMode].
enum SessionPurpose {
  /// A conversation that does not exist yet, whatever it is seeded with.
  newSession,

  /// Continuing a conversation the agent already has a record of.
  existingSession,
}

/// Everything one session-creation entry point has to decide, stated once.
///
/// Every field that used to be resolved differently per call site is here, so
/// the divergence has somewhere to have been removed *to*. A caller that does
/// not care leaves a default; a caller that cares says so, in the same words as
/// every other caller.
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
    this.firstMessage,
    this.parentSessionId,
    this.parentLink,
    this.forkExternalSessionId,
    this.permissionOverride,
    this.modelOverride,
    this.view,
    this.externalTerminal,
  });

  final Repository repository;
  final AgentInstallation installation;
  final String title;

  /// New or existing — the *only* input to permission-mode resolution.
  final SessionPurpose purpose;

  final SessionSurface surface;

  /// Create a **new** worktree for this session.
  final bool useWorktree;

  /// Run in a worktree that already exists, rather than creating one.
  ///
  /// This is what "the handoff continues in the same worktree and on the same
  /// branch" needs, and it could not be said before: [useWorktree] means
  /// *create one*, and leaving it false put the new session in the repository
  /// root — a different directory on a different branch from the work being
  /// handed over, which is the one thing a handoff must not do.
  ///
  /// Mutually exclusive with [useWorktree]; the launcher refuses both.
  final EnvironmentPath? existingWorktree;

  /// Run in this directory rather than the repository root, without claiming
  /// it is a worktree.
  ///
  /// What a handoff, a fork and a resume of an adopted session all need: the
  /// work is in a subdirectory, and starting at the repository root would put
  /// the agent in a tree that is not the one it was working in.
  ///
  /// It used to say that this also protects the *conversation* — "Claude Code
  /// and Codex key their conversation stores by working directory, so starting
  /// at the root can silently open a new conversation". That was checked and is
  /// not true of either: Codex's store is date-keyed with the cwd inside the
  /// file, and Claude Code's resume falls back past its cwd-keyed bucket to a
  /// git-worktree sweep and then a scan of every bucket for the id. See
  /// [AgentResumeLocality], which is where that claim now lives, per agent,
  /// with its evidence — and where an unverified agent still gets the cautious
  /// answer this comment assumed for everybody.
  ///
  /// [existingWorktree] wins when both are set, because it is the stronger
  /// statement — it says the directory is a worktree as well as where to run —
  /// and the two can only ever name the same place.
  final EnvironmentPath? workingDirectory;

  final List<Repository> additionalRepositories;

  /// The CLI's own session id to resume, when continuing one it already wrote.
  final String? resumeExternalSessionId;

  /// Sent as soon as the session is up. One code path, guarded once.
  final String? firstMessage;

  /// The session this one came from, when it came from one. Never supplied by
  /// the model directly — see `SessionDepth`.
  final String? parentSessionId;

  /// Why [parentSessionId] is set. Defaults to null and is read as
  /// [SessionLink.spawn] by the launcher when a parent is named without one,
  /// which keeps the MCP spawn path — the only caller that predates this field
  /// — meaning exactly what it always meant.
  final SessionLink? parentLink;

  /// The CLI's own id for a conversation to **fork**, when the agent forks
  /// natively.
  ///
  /// Separate from [resumeExternalSessionId] because the two produce different
  /// command lines and must never both be honoured: `codex fork <id>` and
  /// `codex resume <id>` are two subcommands, and Claude's fork is its resume
  /// plus a flag. A request carrying both would be asking for one conversation
  /// to be continued and branched at once, which is not a thing.
  final String? forkExternalSessionId;

  /// Escape hatch for a caller that genuinely knows better than the setting.
  /// Unused by any in-app path; kept so "the setting decides" stays true by
  /// inspection rather than by convention.
  final PermissionMode? permissionOverride;

  /// The model this launch should record and run under, or null to leave the
  /// session's own choice — and, failing that, the default — alone.
  ///
  /// Parallel to [permissionOverride] and read the same way: null does not mean
  /// "no model", it means "this caller is not deciding". A resume that passed a
  /// resolved value here would overwrite the choice the model chip made, which
  /// is precisely the bug `Session.permissionMode` documents having had.
  final String? modelOverride;

  /// Forced rendering, or `null` to take the agent's default.
  final SessionView? view;

  /// Which external terminal to launch into, for [SessionSurface.external].
  /// `null` takes the configured default, which is what every in-app caller
  /// should do — the parameter exists for the dialog, where the user picked one.
  final SystemTerminal? externalTerminal;
}
