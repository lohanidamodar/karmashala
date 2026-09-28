part of '../agent_descriptor.dart';

/// Executable base names to probe, per execution-environment kind. Each list is
/// tried in order and the first hit wins.
///
/// There are two lists rather than one per kind because the split that matters
/// is Windows vs POSIX: a WSL distro and a remote SSH host both run `claude`,
/// not `claude.exe`.
class AgentBinaries {
  const AgentBinaries({
    required this.windows,
    required this.posix,
    this.windowsInstallPaths = const [],
  });

  final List<String> windows;
  final List<String> posix;

  /// Exact executables to try on Windows when [windows] finds nothing on PATH,
  /// as `%VAR%`-templated absolute paths.
  ///
  /// **This is the Windows half of a compensation the POSIX branch already
  /// has.** `locateRequest` deliberately runs the POSIX lookup through a login
  /// shell so `~/.local/bin` — where these CLIs install themselves — is on
  /// PATH. Windows gets a bare `where`, which sees only the PATH the app
  /// process inherited when it started. Two things fall through that gap:
  ///
  /// * an agent whose installer never put it on PATH at all. On the machine
  ///   this was reported from, `claude.exe` sits in `%USERPROFILE%\.local\bin`
  ///   and that directory is in neither the user nor the machine PATH, so
  ///   `where claude` can never succeed;
  /// * an agent installed *after* the app process started. A process's PATH is
  ///   a snapshot taken at creation; the broadcast that tells running programs
  ///   the environment changed is one a Flutter app does not act on. Naming the
  ///   installer's own directory makes detection independent of that timing.
  ///
  /// Each entry names **one file**, never a directory to search: discovery
  /// probes exactly these paths and never walks the disk. An entry whose
  /// variables are unset is skipped rather than probed literally.
  final List<String> windowsInstallPaths;

  List<String> forKind(EnvironmentKind kind) =>
      kind == EnvironmentKind.windowsNative ? windows : posix;
}

/// How to confirm a located executable and read its version.
class AgentDiscoveryRules {
  const AgentDiscoveryRules({
    this.probeVersion = true,
    this.versionArguments = const ['--version'],
  });

  final bool probeVersion;
  final List<String> versionArguments;
}

/// How faithfully a [PermissionRisk] survives being carried onto an agent.
///
/// This used to describe the *picker*: a shared three-value mode had to be
/// translated per agent, and the translation could be lossy. It no longer is —
/// each agent declares its own modes in its own words
/// ([AgentPermissionSupport]), so anything a picker offers is exact by
/// construction.
///
/// What remains genuinely lossy is the **carry**: a handoff resolves a rung for
/// one agent and hands it to another that may have nothing at that rung. So the
/// fidelity lives on `CarriedPermission` now, which is the one place a mode
/// really is translated.
enum PermissionModeFit {
  /// The target has a mode at exactly the requested rung.
  exact,

  /// The target's nearest mode is **safer** than what was asked for. Not the
  /// same thing, and never the other direction.
  approximate,

  /// The target has nothing at or below the requested rung, or no declared
  /// modes at all.
  none,
}

/// The command-line vocabulary of one agent.
///
/// [resume] is the headless/protocol convention the adapters use;
/// [interactiveResume] is the one a TTY launch uses. They differ for Codex
/// (`codex --resume <id>` in app-server mode vs `codex resume <id>` in a
/// terminal), which is why both are recorded.
class AgentLaunchSpec {
  const AgentLaunchSpec({
    this.baseArguments = const [],
    this.permission = const AgentPermissionSupport.unknown(),
    this.resume = const AgentResume.unsupported(),
    this.interactiveResume = const AgentResume.unsupported(),
    this.resumeLocality = const AgentResumeLocality.launchDirectory(),
    this.sessionIdAssignment = const AgentSessionIdAssignment.unsupported(),
    this.sessionIdAnnouncement = const AgentSessionIdAnnouncement.none(),
    this.continueLatest = const AgentContinueSupport.unsupported(),
    this.prompt = const AgentPromptSupport.unsupported(),
    this.systemPromptFile = const AgentSystemPromptFileSupport.unchecked(),
    this.allowsConcurrentResume = false,
    this.resumeConflict = const AgentResumeConflictRules(),
    this.missingConversation = const AgentMissingConversationRules(),
    this.firstRunPrompt = const AgentFirstRunPromptRules(),
    this.rejectedValue = const AgentRejectedValueRules.none(),
    this.fork = const AgentForkSupport.unsupported(),
    this.mcp = const AgentMcpSupport.unsupported(),
    this.model = const AgentModelSupport.unsupported(),
    this.recap = const AgentRecapSupport.unchecked(),
    this.selfUpdate = const AgentSelfUpdate.unknown(),
    this.parentSessionEnvironment = const {},
  });

  final List<String> baseArguments;

  /// Variables a running session of this CLI sets for its own children. Any of
  /// them in Karmashala's environment — it was started from inside such a
  /// session — are withheld from the agents it launches, or each would think
  /// it was a child of that session. Only session-bound names: a variable a
  /// person sets on purpose to configure the CLI stays.
  final Set<String> parentSessionEnvironment;

  /// How this agent updates itself, and how Karmashala turns that off for the
  /// processes it launches. See [AgentSelfUpdate]. Defaults to "nobody
  /// established one", which suppresses nothing.
  final AgentSelfUpdate selfUpdate;

  /// How this CLI is asked, non-interactively, to recap a conversation.
  ///
  /// Separate from [prompt] and [baseArguments] because it describes a
  /// *different process*: a recap never types into the running session, it
  /// starts the same binary in print mode and lets it exit. Defaults to
  /// unchecked, so an agent nobody has run this way offers no Recap action
  /// rather than a guessed command line.
  final AgentRecapSupport recap;

  /// This agent's own permission vocabulary, in its own words.
  ///
  /// Declared per agent because the three do not share a shape — see
  /// [AgentPermissionSupport]. Defaults to
  /// [AgentPermissionSupport.unknown], so an agent nobody has established
  /// offers nothing rather than a guess.
  final AgentPermissionSupport permission;

  final AgentResume resume;
  final AgentResume interactiveResume;

  /// Whether [resume]/[interactiveResume] still find the conversation when the
  /// CLI is launched somewhere other than where the conversation was started.
  /// See [AgentResumeLocality]; defaults to "assume not".
  final AgentResumeLocality resumeLocality;

  /// Whether a second process may resume a conversation another process is
  /// already holding.
  ///
  /// This models **whether** concurrent resume is permitted, which is a
  /// different question from [resume]/[interactiveResume]'s *how*, and the
  /// agents differ on it:
  ///
  /// * **Codex refuses.** A thread has one writer, enforced with an flock on
  ///   `~/.codex/thread-writer-locks/<thread>.lock`; a second `codex resume`
  ///   exits with `thread <id> already has an active writer (code -32600)`.
  ///   That is protection for the rollout JSONL — two writers would interleave
  ///   into one transcript — and is not something to work around.
  /// * **Claude Code permits it.** A second `claude --resume <id>` opens on the
  ///   same conversation with its history and stays usable; only its remote
  ///   control declines, in a line it prints itself.
  ///
  /// **False by default**, because the failure modes are asymmetric: refusing a
  /// resume that would have worked costs a click, while attempting one the agent
  /// forbids can corrupt the user's transcript. An agent nobody has tested is
  /// therefore treated as single-writer.
  final bool allowsConcurrentResume;

  /// What this agent prints when it refuses such a resume. Empty for an agent
  /// whose refusal we have never seen — which resolves to "no explanation",
  /// never to a guessed one.
  final AgentResumeConflictRules resumeConflict;

  /// What this agent prints when it is asked to resume a conversation it has no
  /// record of. Empty for an agent whose answer we have never seen, which
  /// resolves to "no explanation" rather than a guessed one.
  final AgentMissingConversationRules missingConversation;

  /// What this agent draws when it will not start in a directory until a
  /// person answers a first-run question about it (directory trust). Empty
  /// for an agent whose question nobody has captured: an unattended launch of
  /// it then waits for its run ceiling rather than being told why.
  final AgentFirstRunPromptRules firstRunPrompt;

  /// What this agent prints when it is handed a flag value the **installed**
  /// build does not have — the one post-mortem whose cause is a claim of ours
  /// rather than a fact about the user's conversations. See
  /// [AgentRejectedValueRules]. Empty by default.
  final AgentRejectedValueRules rejectedValue;

  /// Whether this agent can start a new conversation from an existing one's
  /// history, and how. Defaults to [AgentForkStyle.unsupported].
  final AgentForkSupport fork;

  /// Whether this agent can be pointed at Karmashala's own MCP endpoint on its
  /// command line, and how. Defaults to [AgentMcpStyle.unsupported].
  final AgentMcpSupport mcp;

  /// Whether this agent can be told which model to run, and how. Defaults to
  /// [AgentModelStyle.unsupported], which draws no model control at all.
  final AgentModelSupport model;

  /// Whether this agent will accept a session id we choose. See
  /// [AgentSessionIdAssignment].
  final AgentSessionIdAssignment sessionIdAssignment;

  /// Whether this agent says, in its own output, which session id it chose.
  /// See [AgentSessionIdAnnouncement]. Defaults to "it says nothing".
  final AgentSessionIdAnnouncement sessionIdAnnouncement;

  /// Whether this agent can be told "continue the most recent conversation",
  /// and what "most recent" is scoped to. See [AgentContinueSupport]. Defaults
  /// to unsupported.
  final AgentContinueSupport continueLatest;

  /// Whether this agent takes an opening prompt on its command line, and how.
  /// See [AgentPromptSupport]. Defaults to unsupported.
  ///
  /// This is how a session's first message is delivered: typing it into the PTY
  /// instead would race the agent's own startup, which takes seconds and shows
  /// no reliable "ready" marker.
  final AgentPromptSupport prompt;

  /// Whether this agent takes an extra system prompt as a file, and how. See
  /// [AgentSystemPromptFileSupport]. Defaults to "nobody checked".
  final AgentSystemPromptFileSupport systemPromptFile;

  /// Whether an opening prompt can be delivered at all — [prompt]'s *whether*,
  /// for the refusal gates that only ever asked that. They read the same answer
  /// they always did; what widened underneath them is the *how*.
  bool get acceptsPromptArgument => prompt.isSupported;
}

/// **How an agent updates itself, and how to stop it doing so in a
/// Karmashala-launched process.**
///
/// The behaviour this exists to defend against: a coding-agent CLI that checks
/// for a new version at startup and can replace its own executable — an npm or
/// installer self-update. Launched under an unsigned desktop app, through a
/// shell, that download-and-replace-an-exe step is the tail of a chain
/// behavioural antivirus reads as a dropper, and on the owner's managed machine
/// Bitdefender killed the whole process tree for it (docs/windows-antivirus.md).
///
/// Karmashala does not disable the user's updates in general — only in the
/// processes it launches, and only when the setting says so. Each field is
/// **declared per agent from that agent's own source or docs**, with
/// [evidence], so a version bump can be re-checked rather than trusted.
class AgentSelfUpdate {
  /// Nobody has established how this agent updates: suppress nothing, offer no
  /// update command. The conservative default.
  const AgentSelfUpdate.unknown()
    : disableArguments = const [],
      disableEnvironment = const {},
      updateCommand = const [],
      latestVersion = const AgentLatestVersionSource.none(),
      evidence = '';

  /// This agent checks for or performs updates, and can be told not to.
  ///
  /// [disableArguments] are added to the agent's own command line (Codex's
  /// global `-c check_for_update_on_startup=false`); [disableEnvironment] is
  /// layered over the launched process's environment (Claude Code's
  /// `DISABLE_AUTOUPDATER=1`). [updateCommand] is the documented command that
  /// updates the agent by hand, which Karmashala can offer to run visibly in
  /// its place.
  const AgentSelfUpdate.declared({
    this.disableArguments = const [],
    this.disableEnvironment = const {},
    this.updateCommand = const [],
    this.latestVersion = const AgentLatestVersionSource.none(),
    required this.evidence,
  });

  /// Global command-line arguments that stop the startup update check. They
  /// must be safe to place **left of** any resume/fork subcommand — Codex's
  /// `-c` is a global option, so it is.
  final List<String> disableArguments;

  /// Environment variables that stop the agent updating itself, layered over
  /// the launched process's environment only.
  final Map<String, String> disableEnvironment;

  /// The documented command that updates this agent by hand, executable first.
  /// Empty when none is established.
  final List<String> updateCommand;

  /// Where the newest published version of this agent can be read, so an
  /// install can be called behind without running anything on it. See
  /// [AgentLatestVersionSource]; none by default, which flags nothing.
  final AgentLatestVersionSource latestVersion;

  /// Where [disableArguments]/[disableEnvironment]/[updateCommand] were read
  /// off — the agent's source or docs, and the version. Empty for
  /// [AgentSelfUpdate.unknown].
  final String evidence;

  /// Whether anything here suppresses an update at all.
  bool get canSuppress =>
      disableArguments.isNotEmpty || disableEnvironment.isNotEmpty;

  /// Whether a manual update command is known.
  bool get hasUpdateCommand => updateCommand.isNotEmpty;
}

/// **Where an agent's newest published version is read.**
///
/// Data, like the rest of the descriptor: *which* public document answers
/// "what is the latest release", never how the app asks it. Only a source
/// that is public, unauthenticated and documented is declared — the request
/// carries nothing about the user, and an agent with no such source (a
/// self-updating binary with a private update channel) declares none rather
/// than a scraped guess, and is simply never flagged as behind.
class AgentLatestVersionSource {
  /// Nobody has established a public source: no check, no flag.
  const AgentLatestVersionSource.none() : npmPackage = null, evidence = '';

  /// The agent is published to npm as [npmPackage]; the registry's `latest`
  /// dist-tag document (`GET /<package>/latest`) names the newest version in
  /// its `version` field. Every install channel — npm, the native installer,
  /// `claude update` / `codex update` — ships the same version numbers.
  const AgentLatestVersionSource.npm(
    String this.npmPackage, {
    required this.evidence,
  });

  /// The npm package name, scoped where the vendor scopes it.
  final String? npmPackage;

  /// Where the source was read off, so it can be re-checked rather than
  /// trusted. Empty for [AgentLatestVersionSource.none].
  final String evidence;

  bool get isKnown => npmPackage != null;

  /// The document to fetch, or null when there is none. A scoped name keeps
  /// its `/`: the public registry serves `/@scope/name/latest` as is.
  Uri? get url => switch (npmPackage) {
    final package? => Uri.https('registry.npmjs.org', '/$package/latest'),
    null => null,
  };

  /// A short name for where the version came from, for the settings row.
  String get label => switch (npmPackage) {
    final package? => 'npm $package',
    null => 'no source',
  };
}
