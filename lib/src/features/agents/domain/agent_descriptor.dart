import '../../environments/domain/environment_kind.dart';
import '../../settings/domain/permission_mode.dart';
import 'agent_kind.dart';
import 'agent_status.dart';

/// How an agent CLI expresses "continue this session".
enum AgentResumeStyle {
  /// A flag before the prompt, e.g. `--resume <id>`.
  flag,

  /// A subcommand, e.g. `codex resume <id>`.
  subcommand,

  /// The agent cannot resume from the command line.
  unsupported,
}

/// One agent's resume convention.
class AgentResume {
  const AgentResume.flag(this.token) : style = AgentResumeStyle.flag;
  const AgentResume.subcommand(this.token)
    : style = AgentResumeStyle.subcommand;
  const AgentResume.unsupported()
    : style = AgentResumeStyle.unsupported,
      token = '';

  final AgentResumeStyle style;
  final String token;

  List<String> argumentsFor(String sessionId) =>
      style == AgentResumeStyle.unsupported ? const [] : [token, sessionId];
}

/// How an agent CLI starts a **new** conversation that already contains an
/// existing one's history.
///
/// A fork is not a resume and it is not a fan-out: the new conversation shares
/// everything said so far and then diverges, so the original is left exactly as
/// it was rather than being continued or re-prompted from scratch.
enum AgentForkStyle {
  /// The CLI does it itself, from its own copy of the transcript.
  native,

  /// The CLI cannot, but it will accept a handoff packet as an opening prompt —
  /// so the *history* is carried as text rather than as the agent's own record.
  /// A weaker thing, and the UI must say so before it happens.
  viaHandoff,

  /// Neither. Nothing is offered.
  unsupported,
}

/// Whether one agent can fork a conversation, and how.
///
/// Modelled exactly like [AgentLaunchSpec.allowsConcurrentResume] — declared
/// data on the descriptor, defaulting to the conservative answer — so "Claude
/// forks with a flag, Codex forks with a subcommand, Antigravity cannot" is
/// read from the registry rather than re-derived per call site, and an agent
/// added tomorrow is answered by the same rule.
///
/// **Defaults to [AgentForkStyle.unsupported]**, because the failure modes are
/// asymmetric in the same direction they are for concurrent resume. Not
/// offering a fork that would have worked costs a menu entry; offering one that
/// does not means handing a CLI arguments it will reject, which surfaces to the
/// user as the agent refusing to launch — twice now the exact shape of the
/// worst bug in this area (see the Codex approval flags in
/// `built_in_agents.dart`).
class AgentForkSupport {
  /// The CLI forks by itself. [resume] is how it is told *which* conversation —
  /// a flag for Claude Code, a subcommand for Codex — and [extraArguments] is
  /// whatever else turns that reference into a fork rather than a resume.
  ///
  /// [evidence] is required and is the `--help` line or transcript this was
  /// read off, so the claim can be re-checked against a future CLI version
  /// instead of being trusted because it is written down.
  const AgentForkSupport.native({
    required this.resume,
    this.extraArguments = const [],
    required this.evidence,
  }) : style = AgentForkStyle.native;

  /// The CLI has no fork of its own, but takes an opening prompt, so a handoff
  /// packet is the honest substitute. [evidence] says what was checked.
  const AgentForkSupport.viaHandoff({required this.evidence})
    : style = AgentForkStyle.viaHandoff,
      resume = const AgentResume.unsupported(),
      extraArguments = const [];

  /// Nothing is known to work. The default.
  const AgentForkSupport.unsupported()
    : style = AgentForkStyle.unsupported,
      resume = const AgentResume.unsupported(),
      extraArguments = const [],
      evidence = '';

  final AgentForkStyle style;

  /// How the conversation being forked is named on the command line.
  final AgentResume resume;

  /// Flags that turn [resume]'s reference into a fork.
  final List<String> extraArguments;

  /// Where this was verified. Empty only for [AgentForkStyle.unsupported],
  /// where there is nothing to have verified.
  final String evidence;

  bool get isNative => style == AgentForkStyle.native;

  /// The arguments that fork [externalSessionId], or nothing when this agent
  /// cannot be told.
  ///
  /// These **replace** [AgentLaunchSpec.interactiveResume]'s arguments rather
  /// than joining them: Codex's fork is the `fork` subcommand *instead of*
  /// `resume`, and emitting both would be two subcommands on one command line.
  List<String> argumentsFor(String externalSessionId) =>
      style == AgentForkStyle.native && externalSessionId.isNotEmpty
      ? [...resume.argumentsFor(externalSessionId), ...extraArguments]
      : const [];
}

/// How an agent CLI is told, at launch, where Chitragupta's own tools are.
enum AgentMcpStyle {
  /// A flag naming a config file the agent reads — Claude Code's
  /// `--mcp-config`.
  configFile,

  /// A flag setting one config value inline, with no file — Codex's
  /// `-c <dotted.key>=<value>`.
  inlineUrl,

  /// No convention we have verified. Nothing is passed. **The default.**
  unsupported,
}

/// Whether one agent can be pointed at an MCP server on its command line, and
/// how.
///
/// Modelled exactly like [AgentForkSupport] — declared data on the descriptor,
/// [evidence] required, defaulting to the conservative answer — and for the
/// same reason. Antigravity's descriptor was wrong for months because a flag
/// nobody had run was written down as if it were known; `agy --help` (1.1.22)
/// names an `mcp` *subcommand* for editing its own config and no launch option
/// at all, so Antigravity is given nothing here rather than something plausible.
///
/// Note what this is not: it is not "does the agent support MCP". All three
/// support it. It is "can this launch, without touching the user's own files,
/// add one more server for one session" — and that is a narrower question with
/// a different answer per CLI.
class AgentMcpSupport {
  /// The agent reads a config file named by [flag].
  ///
  /// Emitted as a **single `--flag=value` token**, not as two arguments, and
  /// that is load-bearing rather than cosmetic. Claude Code declares
  /// `--mcp-config <configs...>` — variadic, "space-separated" — so a
  /// space-separated value swallows every following non-flag argument,
  /// including the opening prompt this launcher passes as a positional:
  ///
  ///   $ claude --mcp-config /tmp/c.json mcp list
  ///   Error: Invalid MCP configuration:
  ///   MCP config file not found: …/mcp
  ///   MCP config file not found: …/list
  ///   $ claude --mcp-config=/tmp/c.json mcp list
  ///   claude.ai Google Drive: … ✔ Connected      # ran the subcommand
  ///
  /// Verified against 2.1.251.
  const AgentMcpSupport.configFile({
    required this.flag,
    required this.evidence,
  }) : style = AgentMcpStyle.configFile,
       urlKey = '';

  /// The agent takes the URL on its command line, as `[flag] <urlKey>=<url>`.
  ///
  /// No file is written, so nothing has to be readable from the agent's
  /// filesystem — which is why this is the shape Codex gets even though it also
  /// has a config file: `~/.codex/config.toml` is the *user's*, holds one
  /// `[mcp_servers.chitragupta]` block for the whole machine, and so could
  /// never carry a **per-session** URL. Identity is the point of the URL, so a
  /// convention that cannot be per-session is not a weaker version of this one,
  /// it is a different and wrong thing.
  const AgentMcpSupport.inlineUrl({
    required this.flag,
    required this.urlKey,
    required this.evidence,
  }) : style = AgentMcpStyle.inlineUrl;

  /// Nothing is known to work. The default.
  const AgentMcpSupport.unsupported()
    : style = AgentMcpStyle.unsupported,
      flag = '',
      urlKey = '',
      evidence = '';

  final AgentMcpStyle style;

  /// The option itself, e.g. `--mcp-config` or `-c`.
  final String flag;

  /// For [AgentMcpStyle.inlineUrl], the dotted config key the URL is assigned
  /// to. Empty otherwise.
  final String urlKey;

  /// Where this was verified — the `--help` line or the transcript it was read
  /// off, so a future CLI version can be re-checked rather than trusted.
  final String evidence;

  bool get isSupported => style != AgentMcpStyle.unsupported;

  /// Whether a config file has to exist before [argumentsFor] can say anything.
  bool get needsConfigFile => style == AgentMcpStyle.configFile;

  /// The arguments that point this agent at [url], or nothing when it cannot be
  /// told.
  ///
  /// A [AgentMcpStyle.configFile] agent with no [configPath] gets **nothing**,
  /// not a flag with an empty value: the file could not be written, and a flag
  /// naming a file that is not there is a launch that fails where the launch
  /// without it would have succeeded.
  List<String> argumentsFor({required String url, String? configPath}) =>
      switch (style) {
        AgentMcpStyle.configFile =>
          configPath == null ? const [] : ['$flag=$configPath'],
        AgentMcpStyle.inlineUrl => [flag, '$urlKey=$url'],
        AgentMcpStyle.unsupported => const [],
      };
}

/// Executable base names to probe, per execution-environment kind. Each list is
/// tried in order and the first hit wins.
///
/// There are two lists rather than one per kind because the split that matters
/// is Windows vs POSIX: a WSL distro and a remote SSH host both run `claude`,
/// not `claude.exe`.
class AgentBinaries {
  const AgentBinaries({required this.windows, required this.posix});

  final List<String> windows;
  final List<String> posix;

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

/// How faithfully one [PermissionMode] survives translation into an agent's own
/// command line.
///
/// A property of the **descriptor's declared data**, never of the agent's name:
/// the UI derives what it offers from this, so a user-authored descriptor and a
/// built-in one are read by exactly the same rule.
enum PermissionModeFit {
  /// The CLI has this mode and we ask for it by name. What the user picked is
  /// what runs.
  exact,

  /// The nearest thing the CLI offers, and it is *not* the same thing.
  approximate,

  /// The CLI cannot be told. Nothing is passed and the agent's own default
  /// applies — which we have not verified, so we do not claim it.
  none,
}

/// One permission mode's translation into an agent's command line, together
/// with how faithful that translation is.
///
/// **The fidelity is declared beside the arguments rather than inferred from
/// them**, because the two cases that produce an empty argument list are
/// opposites and no amount of inspecting the list separates them:
///
/// * Claude Code's `ask` is empty because prompting for everything *is* the
///   CLI's default — the mode is exact and needs no flag.
/// * Antigravity's `acceptEdits` was empty because we have no idea how to ask
///   for it — the mode does not map at all.
///
/// Loop 31 §4 named the second the worse of the two silent no-ops, and named
/// `ask` as the sharpest case of it: selecting the *safest* mode and silently
/// getting the agent's unverified default is a worse failure than selecting the
/// most dangerous mode and silently getting the safest behaviour. Its
/// recommendation (option C) was to stop offering what cannot happen.
///
/// So a mode a descriptor cannot express is **absent from the map**, not present
/// with an empty list, and [PermissionModeFit.none] is what absence reads as.
class PermissionModeMapping {
  /// The CLI has this mode and [arguments] name it. [note] is optional and is
  /// for the exact mapping that still deserves a word — an empty argument list
  /// that is empty *because the CLI already behaves this way*.
  const PermissionModeMapping.exact(this.arguments, {this.note})
    : fit = PermissionModeFit.exact;

  /// The closest this CLI comes, which is not the same thing.
  ///
  /// [note] is **required**: an approximation whose shape the user cannot see is
  /// worse than an honest refusal, because they will read the mode's own label
  /// and believe it.
  const PermissionModeMapping.approximate(this.arguments, {required this.note})
    : fit = PermissionModeFit.approximate;

  /// What goes on the command line. May be empty for an [exact] mapping whose
  /// agent already defaults to that behaviour.
  final List<String> arguments;

  final PermissionModeFit fit;

  /// Plain words about what this mode actually does to *this* agent, shown
  /// beside the mode wherever it is offered.
  final String? note;
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
    this.permissionModes = const {},
    this.resume = const AgentResume.unsupported(),
    this.interactiveResume = const AgentResume.unsupported(),
    this.sessionIdAssignment = const AgentSessionIdAssignment.unsupported(),
    this.acceptsPromptArgument = false,
    this.allowsConcurrentResume = false,
    this.resumeConflict = const AgentResumeConflictRules(),
    this.fork = const AgentForkSupport.unsupported(),
    this.mcp = const AgentMcpSupport.unsupported(),
  });

  final List<String> baseArguments;

  /// How each [PermissionMode] is expressed to this agent.
  ///
  /// **A mode this agent cannot be put into is omitted**, never mapped to an
  /// empty list — see [PermissionModeMapping]. Everything the UI offers comes
  /// from the keys of this map.
  final Map<PermissionMode, PermissionModeMapping> permissionModes;

  final AgentResume resume;
  final AgentResume interactiveResume;

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

  /// Whether this agent can start a new conversation from an existing one's
  /// history, and how. Defaults to [AgentForkStyle.unsupported].
  final AgentForkSupport fork;

  /// Whether this agent can be pointed at Chitragupta's own MCP endpoint on its
  /// command line, and how. Defaults to [AgentMcpStyle.unsupported].
  final AgentMcpSupport mcp;

  /// Whether this agent will accept a session id we choose. See
  /// [AgentSessionIdAssignment].
  final AgentSessionIdAssignment sessionIdAssignment;

  /// Whether a trailing positional argument is taken as the opening prompt.
  ///
  /// This is how a session's first message is delivered: typing it into the PTY
  /// instead would race the agent's own startup, which takes seconds and shows
  /// no reliable "ready" marker. Defaults to **false**, so an agent nobody has
  /// checked is launched bare rather than handed a stray argument it may read as
  /// a subcommand.
  final bool acceptsPromptArgument;

  /// The arguments for [mode], or nothing when this agent cannot be told.
  ///
  /// Unchanged in shape and meaning for every launch call site: a mode the
  /// descriptor cannot express still contributes no arguments, because there is
  /// nothing truthful to contribute. What changed around it is that the UI no
  /// longer *offers* such a mode — see [permissionFitFor] and
  /// [expressiblePermissionModes].
  List<String> permissionArgumentsFor(PermissionMode mode) =>
      permissionModes[mode]?.arguments ?? const [];

  /// How faithfully [mode] maps onto this agent; [PermissionModeFit.none] when
  /// the descriptor does not declare it.
  PermissionModeFit permissionFitFor(PermissionMode mode) =>
      permissionModes[mode]?.fit ?? PermissionModeFit.none;

  /// The descriptor's own words about what [mode] does to this agent, or `null`
  /// when it has nothing to add.
  String? permissionNoteFor(PermissionMode mode) => permissionModes[mode]?.note;

  /// The modes this agent can actually be put into, in [PermissionMode]'s own
  /// order (safest first).
  ///
  /// This is the list a permission control should offer. It is derived from the
  /// declared mappings and from nothing else, so an agent added tomorrow —
  /// built-in or user-authored — is answered by the same rule as the three that
  /// ship today.
  List<PermissionMode> get expressiblePermissionModes => [
    for (final mode in PermissionMode.values)
      if (permissionModes.containsKey(mode)) mode,
  ];
}

/// The on-disk layout of an agent's session store.
enum AgentStoreFormat {
  /// `<home>/projects/<dir>/<id>.jsonl`, read by `ClaudeStoreReader`.
  claudeJsonl,

  /// `<home>/sessions/**/rollout-*.jsonl`, read by `CodexStoreReader`.
  codexRollout,

  /// A store we cannot read yet.
  none,
}

/// Where an agent keeps its per-user config and sessions.
class AgentStoreSpec {
  const AgentStoreSpec({required this.homeDirectoryName, required this.format});

  /// Directory name under the environment's home, e.g. `.claude`.
  final String homeDirectoryName;

  final AgentStoreFormat format;
}

/// The best status source an agent supports. The status service falls back down
/// the sources it actually has, so this is a preference, not an exclusive
/// choice.
enum AgentStatusStrategy { hooks, stateFile, terminalGrid, none }

/// Everything Chitragupta needs to find, launch and observe one agent CLI.
///
/// This is data, not code: adding an agent means adding a descriptor. [id] is
/// the agent's identity everywhere — discovery, persistence, settings, sessions
/// and the MCP control server all key on it.
///
/// [kind] is non-null only for the agents that additionally have a hand-written
/// protocol adapter, and is read only when choosing that adapter. A descriptor
/// without one is a complete, usable agent.
class AgentDescriptor {
  const AgentDescriptor({
    required this.id,
    required this.displayName,
    this.kind,
    required this.binaries,
    this.discovery = const AgentDiscoveryRules(),
    this.launch = const AgentLaunchSpec(),
    this.store,
    this.statusStrategy = AgentStatusStrategy.none,
    this.hooks,
    this.stateFile,
    this.grid = const AgentGridRules(),
    this.approval = const AgentApprovalRules(),
  });

  final String id;
  final String displayName;
  final AgentKind? kind;
  final AgentBinaries binaries;
  final AgentDiscoveryRules discovery;
  final AgentLaunchSpec launch;
  final AgentStoreSpec? store;
  final AgentStatusStrategy statusStrategy;
  final AgentHookSpec? hooks;
  final AgentStateFileRules? stateFile;

  /// How to read this agent's status off its own TUI. Empty for an agent whose
  /// screen we have never looked at, which resolves to `unknown` rather than a
  /// guess.
  final AgentGridRules grid;

  /// Which keys answer this agent's approval prompt, when it names any.
  ///
  /// Empty for an agent whose prompt we have never read, so an approval from it
  /// is surfaced but not answerable from the chat view — which is the honest
  /// outcome, not a gap. Pressing keys into a TUI on a guess is the one failure
  /// mode worse than making the user switch to the terminal.
  final AgentApprovalRules approval;

  @override
  String toString() => 'AgentDescriptor($id)';
}

/// Whether an agent lets us choose its session id, and how.
///
/// This is the difference between knowing a PTY-hosted session's CLI id at
/// launch and having to go looking for it afterwards. Claude Code takes
/// `--session-id <uuid>`; Codex has no equivalent and its id can only be
/// discovered from the rollout file it writes. Recording that as a capability
/// keeps the asymmetry in the registry instead of in an `if` somewhere.
class AgentSessionIdAssignment {
  const AgentSessionIdAssignment.flag(this.token) : isSupported = true;
  const AgentSessionIdAssignment.unsupported()
    : token = '',
      isSupported = false;

  final String token;
  final bool isSupported;

  /// The arguments that pin the agent's session id to [sessionId], or nothing
  /// when the agent cannot be told.
  ///
  /// [sessionId] must be a UUID; Chitragupta's own session ids already are (see
  /// `RandomIdGenerator`), which is what lets one string be both.
  List<String> argumentsFor(String sessionId) =>
      isSupported ? [token, sessionId] : const [];
}
