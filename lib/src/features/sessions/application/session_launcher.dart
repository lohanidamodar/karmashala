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
import 'session_launch_exceptions.dart';
import 'session_mcp_arguments.dart';
import 'session_providers.dart';
import 'session_status_providers.dart';
import 'session_ui_providers.dart';
import 'session_working_directory.dart';

// The four refusals are a library of their own — they carry no state, only
// words — and are re-exported here because every caller already reaches for
// them through the launcher.
export 'session_launch_exceptions.dart';

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
part 'session_launcher_input.dart';

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
