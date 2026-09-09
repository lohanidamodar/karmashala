import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm2/xterm.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../agents/application/agent_installations_controller.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_descriptor.dart';
import '../../agents/domain/agent_installation.dart';
import '../../agents/domain/agent_status.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../cli_detection/domain/conversation_presence.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/application/environment_resolver.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';
import '../../git/application/git_providers.dart';
import '../../mcp/session_mcp.dart';
import '../../repositories/application/repository_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../../agents/domain/agent_permission_support.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../terminal/data/pty_launch.dart';
import '../../terminal/data/system_terminal_service.dart';
import '../../terminal/domain/agent_pane_launch.dart';
import '../../terminal/domain/enter_key_encoding.dart';
import '../../terminal/domain/launch_context.dart';
import '../../terminal/domain/pane_liveness.dart';
import '../data/session_repository_dao.dart';
import '../domain/session.dart';
import '../domain/session_attribution.dart';
import '../domain/session_depth.dart';
import '../domain/session_launch.dart';
import '../domain/session_lineage.dart';
import '../domain/session_naming.dart';
import '../domain/session_model.dart';
import '../domain/session_permission.dart';
import '../domain/session_resume.dart';
import '../domain/session_status.dart';
import 'decision_recorder.dart';
import 'handoff_packet_files.dart';
import 'session_mcp_arguments.dart';
import 'session_providers.dart';
import 'session_status_providers.dart';
import 'session_ui_providers.dart';
import 'session_working_directory.dart';

// The launcher's own body, split into one file per concern. They are `part`s
// rather than libraries of their own because privacy in Dart is per library:
// every verb below reads `_ref`, logs through `_log`, and calls the private
// starters that put a process on a surface. What stays here is the class — its
// one field, the shared lookups, the publish path — and the result it hands
// back.
part 'session_launcher_start.dart';
part 'session_launcher_resume_guards.dart';
part 'session_launcher_policy.dart';
part 'session_launcher_surfaces.dart';

/// What a launch produced.
class SessionLaunchResult {
  const SessionLaunchResult({
    required this.session,
    this.paneId,
    this.tabId,
    this.workingDirectoryNotice,
  });

  final Session session;
  final String? paneId;
  final String? tabId;

  /// Plain words for the user when the session could not start where it was
  /// recorded as running, and started somewhere else instead.
  ///
  /// Null in the ordinary case. Non-null is not a failure — the session is up —
  /// but it is the one thing the user must be told, because the agent is now
  /// looking at a different tree from the one its transcript describes.
  ///
  /// It used to justify itself with "a resume in the wrong directory is how an
  /// agent CLI quietly opens a new conversation". That is the cmux claim, and it
  /// does not survive contact with the three CLIs we launch — see
  /// [AgentResumeLocality]. An agent for which it *would* be true never reaches
  /// this notice at all: [SessionLauncher.refuseIfConversationIsElsewhere]
  /// refuses the launch instead.
  final String? workingDirectoryNotice;
}

/// Raised when the recursion cap or the cycle guard refuses a launch.
///
/// Its own type so the MCP surface can fail the caller's *turn* with the
/// explanation rather than reporting a generic error.
class SessionDepthRefused implements Exception {
  const SessionDepthRefused(this.depth);
  final SessionDepth depth;

  @override
  String toString() => depth.refusal;
}

/// Raised when a launch was asked to carry an opening message that the agent's
/// command line cannot take.
///
/// Its own type for the same reason as [SessionDepthRefused]: the MCP surface
/// and fan-out both need to fail the caller with the explanation, rather than
/// starting an agent that never hears the instruction and reporting success.
class SessionLaunchRefused implements Exception {
  const SessionLaunchRefused(this.reason);
  final String reason;

  @override
  String toString() => reason;
}

/// Raised when a resume would start a **second** agent on a conversation whose
/// first one is still running, **and that agent will not share it**.
///
/// Loop 38 separated session lifetime from view lifetime: closing a tab detaches
/// the view and leaves the process running. So "resume this session" stopped
/// meaning "nothing is running it" — and launching anyway hands the agent CLI a
/// transcript it already holds open. Codex refuses that outright:
///
/// ```
/// thread/resume failed: thread <id> already has an active writer (code -32600)
/// ```
///
/// which reaches the user as a raw JSON-RPC failure during TUI bootstrap. That
/// string never reaches the user from here: [toString] is the plain-words
/// version, and it is what the UI shows.
///
/// **Only thrown for an agent that forbids it.** Loop 46 made that conditional:
/// this used to fire for every agent, which refused the case Claude Code
/// actually supports — a second terminal listening to the same conversation.
/// See [AgentLaunchSpec.allowsConcurrentResume] and [resumeActionFor].
///
/// In-app surfaces that *can* reopen the running view do so instead and never
/// get here, so this is thrown where reopening is not what was asked for —
/// handing the session to an external terminal — and by [SessionLauncher.launch]
/// itself, as the backstop no future caller can forget.
class SessionAlreadyRunning implements Exception {
  const SessionAlreadyRunning({
    required this.agentName,
    this.sessionId,
    this.title,
  });

  /// The session already running it — the one to reveal. Null when the holder is
  /// a process we do not own, which we only ever learn from the agent's own
  /// refusal.
  final String? sessionId;

  /// That session's title, when it is one of ours.
  final String? title;

  /// The agent's display name, so the refusal says *who* is refusing. Naming it
  /// is what makes "start a new session instead" read as a property of this CLI
  /// rather than a limitation of Karmashala.
  final String agentName;

  @override
  String toString() {
    final where = title == null
        ? 'That conversation is already open in another process.'
        : '"$title" is already running in Karmashala.';
    return '$where ${resumeBlockedMessage(agentName)}';
  }
}

/// Raised when a resume names a conversation the agent's own store has never
/// held.
///
/// The other side of `sessionIdAssignment`. Passing Claude Code our id as
/// `--session-id` is what lets a row know its conversation without parsing
/// anything, but it also means the row records that id **before** the CLI has
/// written a single byte — so a launch that failed, or a session nothing was
/// ever said in, leaves a row claiming a conversation that does not exist.
/// Nothing distinguished such a row from a real one, and resuming it ran
///
/// ```
/// No conversation found with session ID: 4b13c55e-…
/// [process exited with code 1]
/// ```
///
/// on the user's screen while the app said nothing and went on creating
/// sessions around it.
///
/// **Only thrown on certain knowledge.** The store must have been read to the
/// end without the conversation in it; a store we could not locate or reach
/// answers `unknown` and the resume proceeds exactly as it did before (see
/// `conversationPresenceProvider`).
class SessionConversationMissing implements Exception {
  const SessionConversationMissing({
    required this.agentName,
    required this.conversationId,
    this.sessionId,
    this.title,
  });

  /// The CLI id that names nothing. Included in [toString] because a user whose
  /// store is configured somewhere unusual needs to be able to go and look.
  final String conversationId;

  /// Our row for it, so a caller can reveal or tidy it.
  final String? sessionId;

  /// That row's title, for the message.
  final String? title;

  /// The agent's display name, so the sentence says who has no record.
  final String agentName;

  @override
  String toString() {
    final what = title == null ? 'This session' : '"$title"';
    return '$what cannot be resumed: '
        '${resumeMissingConversationMessage(agentName)} '
        '(conversation id $conversationId)';
  }
}

/// Every launch says what it decided.
///
/// This path had no logging at all, and four of the bugs found in it were
/// silent by construction: a permission mode written over the row it was
/// reusing, `external_session_id` never stored for one agent, a resume that
/// quietly started a new conversation, and a dormant pane not being reused so
/// one session got two terminals. None of them threw; each produced a
/// plausible-looking session that was wrong in a way only the command line
/// showed. One line per launch, naming what was chosen, is what makes the
/// next one of those answerable from a log instead of a repro.
///
/// A library-private top-level rather than a `static` on [SessionLauncher]:
/// the launcher's verbs live in the `part` files beside this one, and an
/// extension cannot name a static of the type it extends unqualified.
final _log = AppLogger.named('sessions.launch');

/// **The** way a session comes into existence.
///
/// Loop 33's audit (§6) found nine entry points reaching four mechanisms, only
/// two of which wrote a `sessions` row; permission mode resolved in eight places
/// with three different answers; and `useWorktree` reachable from one path of
/// nine. This class is where those decisions were moved to. dray's rule is the
/// target: a session created by an agent "is not a second kind of session."
///
/// Three things follow from that and are worth stating, because each was a
/// divergence:
///
/// * **Every in-app session runs in a PTY**, whatever agent it is. The three
///   agents with a protocol adapter do not get a different runtime; they get a
///   second *view* over the same one (see [SessionView]). An adapter is an
///   enhancement layer and is never load-bearing for whether the session is
///   alive.
/// * **Every started session gets a row**, including one launched into an
///   external terminal. Those used to change real-world state with no record and
///   no UI feedback, surfacing later as an unrelated `ImportedSession`.
/// * **Permission mode is resolved here and nowhere else**, from the caller's
///   [SessionPurpose].
class SessionLauncher {
  SessionLauncher(this._ref);

  final Ref _ref;

  /// The single default-installation resolution.
  ///
  /// Four variants of this existed, and only some of them consulted the user's
  /// configured default at all.
  AgentInstallation? defaultInstallationIn(String environmentId) {
    final installs = _ref
        .read(agentInstallationDaoProvider)
        .getByEnvironment(environmentId);
    if (installs.isEmpty) return null;
    final settings = _ref.read(settingsControllerProvider);
    return resolveDefaultInstallation(
          installs,
          defaultInstallationId: settings.defaultAgentInstallationId,
          defaultAgentId: settings.defaultAgent,
        ) ??
        installs.first;
  }

  /// Creates the session row and starts it on the requested surface.
  ///
  /// The body is `_launch` in `session_launcher_start.dart`, and this line is
  /// why it is not simply named `launch` there: an extension member cannot be
  /// overridden, and two test doubles replace this method by subclassing the
  /// launcher. Moving it out under its own name would leave those overrides
  /// declared, unused and never called — the silent kind of wrong.
  Future<SessionLaunchResult> launch(SessionLaunchRequest request) =>
      _launch(request);

  /// Where a depth walk reads from. Exposed so the MCP surface can check the cap
  /// before doing any work it would have to undo.
  SessionDepth depthForChildOf(String? parentSessionId) =>
      SessionDepth.forChildOf(
        parentSessionId,
        _ref.read(sessionDaoProvider).parentOf,
      );

  /// The attribution for text a *session* is putting into another session's
  /// input, or `null` when no session can be named for it.
  ///
  /// Two callers, one prefix: the opening prompt of a session an agent spawned
  /// (where [senderSessionId] is the parent), and `session_send` relaying a
  /// message (where it is the caller the MCP transport authenticated). They
  /// build the line from the same place on purpose — the strip rebuilds it
  /// rather than parsing it, so a second format would be a line nothing knows
  /// how to remove.
  ///
  /// Null for a sender with no session of its own and for a row that has gone.
  /// Naming a sender we cannot read would be inventing provenance, which is the
  /// failure the prefix exists to close rather than a smaller version of it.
  SessionAttribution? attributionFor(String? senderSessionId) {
    if (senderSessionId == null) return null;
    final sender = _ref.read(sessionDaoProvider).getById(senderSessionId);
    if (sender == null) return null;
    return SessionAttribution(sessionId: sender.id, title: sender.title);
  }

  /// Types [text] into a PTY-hosted session, exactly as if the user had.
  ///
  /// This is what "the composer and the terminal are two views of one session"
  /// means at the input end: there is no second write path into the agent, so a
  /// message sent from chat and one typed into the pane are indistinguishable to
  /// the CLI, and neither can get out of step with the other.
  ///
  /// Returns false when the session has no live pane — a restored record, an
  /// external terminal, or a session that has ended — so the caller can say so
  /// rather than silently dropping the message.
  bool sendTo(String sessionId, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    final terminal = _liveTerminalFor(sessionId);
    if (terminal == null) return false;
    // A carriage return, not a newline: a PTY line discipline reads CR as
    // "submit", and a bare LF leaves the text sitting in the agent's composer.
    //
    // The `Ctrl+E` between them is what makes that CR arrive as a keypress.
    // Measured 2026-09-08 against a real ConPTY: Codex 0.153.4 leaves the
    // message sitting in its composer, on Windows and in WSL alike, because
    // `paste_burst.rs` reads characters that arrive with no gap as a paste and
    // folds a Return inside that run into a newline. Anything that is not a
    // character ends the run; `Ctrl+E` is the smallest such thing, and it
    // only asserts what is already true — the caret is at the end of the line.
    terminal
      ..textInput(trimmed)
      ..textInput(kEndOfLineKey)
      ..textInput('\r');
    return true;
  }

  /// Answers an agent's on-screen prompt by pressing [keys] in its terminal.
  ///
  /// Separate from [sendTo] rather than a special case of it, because the two
  /// are different acts. [sendTo] delivers a *message*: it trims, refuses empty
  /// input and appends a carriage return to submit it. An answer is a
  /// **keystroke** — `\r`, `\x1b` — where trimming would erase the whole
  /// payload and an appended return would press a second key nobody asked for.
  ///
  /// [keys] must come from the agent's own [AgentApprovalRules]. Nothing here
  /// invents a binding: this method presses what it is given, and the registry
  /// is what decides whether there is anything to press.
  ///
  /// Returns false when the session has no live pane, so the caller can say the
  /// answer did not land instead of assuming it did.
  ///
  /// **This is where an approval reaches the decision record**, and it is the
  /// only place both answering paths meet: the approval card presses these
  /// keys and so does `session_answer`. Recording here means the packet carries
  /// what the user allowed however they allowed it, rather than only what came
  /// through the bridge.
  ///
  /// [decidedBy] names who answered — the user by default, since the card is
  /// the ordinary route; `session_answer` passes the agent that called it.
  bool answerPrompt(
    String sessionId,
    String keys, {
    String decidedBy = 'the user',
    String? decidedBySessionId,
  }) {
    if (keys.isEmpty) return false;
    final terminal = _liveTerminalFor(sessionId);
    if (terminal == null) return false;
    terminal.textInput(keys);
    _recordAnswer(
      sessionId,
      keys,
      decidedBy: decidedBy,
      decidedBySessionId: decidedBySessionId,
    );
    return true;
  }

  /// Writes the answered prompt to the session's decision record, when the
  /// keystroke is one the agent itself named.
  ///
  /// **A table lookup, not an interpretation.** [keys] is matched against the
  /// agent's own [AgentApprovalRules] — the same table the card read to draw
  /// the button — so what is recorded is the agent's own words for what that
  /// key does. Keys that match neither answer record *nothing*: this method
  /// also carries whatever an agent's prompt was answered with by some other
  /// route, and guessing at what an unrecognised keystroke authorised is
  /// exactly the inference the record must never contain.
  void _recordAnswer(
    String sessionId,
    String keys, {
    required String decidedBy,
    required String? decidedBySessionId,
  }) {
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) return;
    final agentId = _ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId)
        ?.agentId;
    if (agentId == null) return;
    final rules =
        _ref.read(agentRegistryProvider).byId(agentId)?.approval ??
        const AgentApprovalRules();
    final granted = rules.approve?.keys == keys;
    final answer = granted ? rules.approve : rules.deny;
    if (answer == null || answer.keys != keys) return;
    _ref
        .read(decisionRecorderProvider)
        .recordApproval(
          sessionId: sessionId,
          granted: granted,
          effect: answer.effect,
          answerLabel: answer.label,
          decidedBy: decidedBy,
          decidedBySessionId: decidedBySessionId,
        );
  }

  void _publish(SessionChange change) =>
      _ref.read(sessionsRevisionProvider.notifier).changed(change);
}

/// The interactive command-line arguments for one agent launch.
///
/// Shared by the pane and external-terminal surfaces so the two cannot drift:
/// "open this in Windows Terminal instead" must produce the same agent, in the
/// same mode, on the same conversation.
///
/// Order matters and is the order the shipped agents want: the MCP flag, then
/// global flags, then the session-id flag, then the resume convention (which
/// for Codex is a *subcommand* and must follow the globals), then the prompt in
/// whichever shape the descriptor's [AgentPromptSupport] names — a trailing
/// positional for Claude and Codex, a flag and its value for Antigravity.
///
/// [systemPromptFilePath] rides with the globals for the same reason the model
/// flag does, and is the handoff packet's way in for an agent that takes one.
///
/// [forkSessionId] **replaces** the resume convention rather than adding to it:
/// Codex forks with a `fork` subcommand *instead of* `resume`, and emitting
/// both would put two subcommands on one command line. Claude's fork is its own
/// resume plus `--fork-session`, which its [AgentForkSupport] states, so both
/// shapes come out of one call.
List<String> agentPaneArguments(
  AgentDescriptor? descriptor,
  PermissionSelection permissionMode, {
  String? modelId,
  String? sessionId,
  String? resumeSessionId,
  String? forkSessionId,
  String? prompt,
  String? systemPromptFilePath,
  String? mcpUrl,
  String? mcpConfigPath,
}) {
  final launch = descriptor?.launch;
  final trimmedPrompt = prompt?.trim();
  final forking = forkSessionId != null && forkSessionId.isNotEmpty;
  return [
    // First, because Codex's `-c` is a global option and its resume is a
    // *subcommand*: everything global has to be on the left of it. Nothing
    // here is variadic — Claude's config flag is deliberately one
    // `--flag=value` token — so nothing downstream can be swallowed.
    ...agentMcpArguments(descriptor, url: mcpUrl, configPath: mcpConfigPath),
    ...?launch?.permission.argumentsFor(permissionMode),
    // Beside the permission flags and for the same reason: a global option, so
    // it has to be left of Codex's `resume`/`fork` subcommand. Nothing is
    // emitted for a null model or an agent that takes none.
    ...?launch?.model.argumentsFor(modelId),
    // A global too, and it belongs beside them: the file is context for the
    // whole session rather than something the resume or the prompt carries.
    // Nothing is emitted for an agent that takes none, so a packet aimed at one
    // stays where it was — in the opening prompt.
    ...?launch?.systemPromptFile.argumentsFor(systemPromptFilePath),
    if (sessionId != null && resumeSessionId == null && !forking)
      ...?launch?.sessionIdAssignment.argumentsFor(sessionId),
    if (forking) ...?launch?.fork.argumentsFor(forkSessionId),
    if (!forking && resumeSessionId != null && resumeSessionId.isNotEmpty)
      ...?launch?.interactiveResume.argumentsFor(resumeSessionId),
    // Last, and spread rather than appended: the prompt is a positional for
    // Claude and Codex but two argv entries for Antigravity, and which of those
    // it is belongs to the descriptor rather than to this call site.
    if (trimmedPrompt != null) ...?launch?.prompt.argumentsFor(trimmedPrompt),
  ];
}

final sessionLauncherProvider = Provider<SessionLauncher>(
  (ref) => SessionLauncher(ref),
);
