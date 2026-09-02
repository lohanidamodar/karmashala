import '../../agents/domain/agent_descriptor.dart';
import '../../agents/domain/agent_registry.dart';

/// The environment variable an agent running in one of our panes is told its
/// Karmashala session id through.
///
/// It is how a session an agent creates finds its parent: the MCP bridge is
/// spawned as a child of the agent CLI, inherits this, and forwards it with
/// every tool call. That makes the parent chain a property of the process tree
/// we built rather than of an argument the model writes, which is what the
/// recursion cap needs to be worth anything.
const String kSessionIdEnvironmentVariable = 'KARMASHALA_SESSION_ID';

/// The environment variable carrying a **port base** derived from that session
/// id, so two sessions running the same repository's scripts at once do not
/// both bind 8080.
///
/// The gap this closes is the one `docs/compare-cmux.md` F5(a) names: a worktree
/// isolates the *files* and nothing else. cmux derives every shared resource in
/// its own stack from one seed per workspace — `CMUX_PORT` gives the dev port,
/// the Postgres port at `+10000`, the test database at `+30000`, and the Docker
/// container and network names — and its worktree prototype does the same in
/// miniature (`let port = 4_100 + abs(branchName.hashValue % 800)`). We had one
/// stamped variable and no per-session ports at all.
///
/// It is a **namespace, not a lock**, and the difference matters enough to say
/// twice. Nothing here reserves a port, checks whether one is free, or notices a
/// collision; a repository's own scripts and `AGENTS.md` opt in by reading the
/// variable, and a repository that ignores it collides exactly as it does today.
/// Two sessions can also land on the same base — see [sessionPortBase] for the
/// odds. What it buys is that N *different* sessions almost always get N
/// different numbers, deterministically, for free, and that the number is stable
/// across a restart because it is a function of the session id and nothing else.
const String kSessionPortBaseEnvironmentVariable = 'KARMASHALA_PORT_BASE';

/// The lowest port [sessionPortBase] will hand out.
///
/// 20000 is chosen to sit below **both** default ephemeral ranges — Linux
/// starts at 32768, Windows at 49152 — so a derived port is never one the OS
/// may already have given to something else. The window between 20000 and those
/// floors is what [kSessionPortBaseSlots] divides up.
const int kSessionPortBaseFloor = 20000;

/// How many ports each session's base reserves *by convention*.
///
/// Ten, because a repository that wants more than one — a dev server, a
/// database, a mock API — should be able to say `base + 1`, `base + 2` without
/// stepping on the next session, and because ten into the available window
/// leaves enough slots to make collisions rare.
const int kSessionPortsPerSession = 10;

/// How many distinct bases exist: `(32760 - 20000) / 10`.
const int kSessionPortBaseSlots = 1276;

/// A deterministic port base for [sessionId], in
/// `[kSessionPortBaseFloor, 32760)` and always a multiple of
/// [kSessionPortsPerSession].
///
/// **It can collide, and it is not allowed to pretend otherwise.** With 1276
/// slots, ten sessions running at once have roughly a 3.5% chance that some two
/// of them share a base (45 pairs over 1276). That is the price of being a pure
/// function of the id — which is what makes the number survive a restart, an
/// app upgrade and a session resumed tomorrow, none of which an allocated port
/// would. cmux's own prototype makes the same trade with 800 slots.
///
/// The hash is written out rather than taken from `sessionId.hashCode`: Dart
/// does not promise `String.hashCode` is stable across runs or versions, and a
/// base that changed under a resumed session would be worse than no base at all.
int sessionPortBase(String sessionId) {
  // FNV-1a, 32-bit, masked at every step so it stays inside a JS-safe integer
  // on web as well as native.
  var hash = 0x811c9dc5;
  for (final unit in sessionId.codeUnits) {
    hash = (hash ^ unit) & 0xffffffff;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return kSessionPortBaseFloor +
      (hash % kSessionPortBaseSlots) * kSessionPortsPerSession;
}

/// A pane that runs an agent CLI interactively rather than a shell.
///
/// This is the whole of "adding an agent is a data entry" at the terminal layer:
/// the executable and arguments are resolved from the agent's registry
/// descriptor and its installation, and nothing here knows which agent it is
/// beyond [agentId] being carried along for status detection.
///
/// [executable], [arguments] and [workingDirectory] are all expressed in the
/// **target** environment. When [wslDistribution] is set they are Linux-side
/// values that get wrapped in `wsl.exe`; otherwise they are Windows-side.
class AgentPaneLaunch {
  const AgentPaneLaunch({
    required this.agentId,
    required this.executable,
    this.arguments = const [],
    this.mcpArguments = const [],
    this.workingDirectory,
    this.wslDistribution,
    this.sessionId,
    this.title,
  });

  /// `AgentDescriptor.id` — what the grid status source looks the rules up by.
  final String agentId;

  final String executable;

  /// The **durable** arguments: the permission mode, the session or resume id,
  /// the opening prompt. Everything here means the same thing tomorrow as it
  /// does today, which is what makes it safe to store.
  final List<String> arguments;

  /// The **volatile** arguments: the flags pointing this agent at the app's own
  /// MCP endpoint. Rebuilt at every launch and never stored.
  ///
  /// Every value inside them dies with the app process that minted them —
  /// `SessionMcpConfigs.prepare` deletes the config directory on the way in,
  /// the control server binds whatever port it can get, and the URL's last path
  /// segment is a credential for this run only. Storing them made a restored
  /// pane replay yesterday's, and the agent refused to start at all:
  ///
  ///   Error: Invalid MCP configuration:
  ///   MCP config file not found: `…/karmashala/mcp/session-<uuid>.json`
  ///
  /// See `agentPaneMcpArgumentsProvider`, which is what a restart asks.
  final List<String> mcpArguments;

  /// The command line as it is actually run: the volatile flags, then the
  /// durable ones.
  ///
  /// MCP first, because Codex's `-c` is a global option and its resume is a
  /// *subcommand* — everything global has to be on the left of it. The same
  /// order `agentPaneArguments` emits for the external-terminal surface, and
  /// `agent_pane_launch_test.dart` holds the two to it.
  List<String> get commandArguments => [...mcpArguments, ...arguments];

  /// Directory the agent starts in, in its own environment.
  final String? workingDirectory;

  /// The WSL distribution to wrap the launch in, or `null` for a Windows-native
  /// (or already-POSIX host) launch.
  final String? wslDistribution;

  /// The `sessions` row this pane belongs to, when it has one.
  final String? sessionId;

  /// The tab label. Defaults to the agent id when absent.
  final String? title;

  /// The profile id a pane running this launch is stored under.
  ///
  /// It deliberately does not resolve through [terminalProfileFromId]: an agent
  /// pane is restored from its recorded launch, not from a shell profile, and a
  /// synthetic id that *did* resolve would silently come back as PowerShell.
  String get profileId => 'agent:$agentId';

  /// Whether [profileId] names an agent pane rather than a shell profile.
  static bool isAgentProfileId(String id) => id.startsWith('agent:');

  /// This launch armed with the MCP flags of *now*.
  AgentPaneLaunch withMcpArguments(List<String> mcpArguments) =>
      AgentPaneLaunch(
        agentId: agentId,
        executable: executable,
        arguments: arguments,
        mcpArguments: mcpArguments,
        workingDirectory: workingDirectory,
        wslDistribution: wslDistribution,
        sessionId: sessionId,
        title: title,
      );

  /// [mcpArguments] is deliberately absent: what is stored is the launch's
  /// durable *intent*, and a flag naming this run's port, credential and config
  /// file is no part of it.
  Map<String, Object?> toJson() => {
    'agentId': agentId,
    'executable': executable,
    'arguments': arguments,
    if (workingDirectory != null) 'workingDirectory': workingDirectory,
    if (wslDistribution != null) 'wslDistribution': wslDistribution,
    if (sessionId != null) 'sessionId': sessionId,
    if (title != null) 'title': title,
  };

  /// Rebuilds a launch from stored JSON, or `null` when the record is not one
  /// this code wrote. Forgiving on purpose: a pane that cannot be read back is
  /// dropped, never thrown on.
  ///
  /// Always comes back with [mcpArguments] empty — a stored record has no
  /// business carrying them, and one written before that was true has them
  /// taken out. The pane is armed again at the moment it is started, from the
  /// server running then.
  static AgentPaneLaunch? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final agentId = raw['agentId'];
    final executable = raw['executable'];
    if (agentId is! String || agentId.isEmpty) return null;
    if (executable is! String || executable.isEmpty) return null;
    final stored = [
      for (final argument in (raw['arguments'] as List?) ?? const [])
        if (argument is String) argument,
    ];
    // A record written before the MCP flags were understood to be volatile has
    // them inside `arguments`, and the owner's saved layout is full of
    // those. See [AgentMcpSupport.withoutArgumentsIn].
    final mcp =
        AgentRegistry.builtIn.byId(agentId)?.launch.mcp ??
        const AgentMcpSupport.unsupported();
    return AgentPaneLaunch(
      agentId: agentId,
      executable: executable,
      arguments: mcp.withoutArgumentsIn(stored),
      workingDirectory: raw['workingDirectory'] as String?,
      wslDistribution: raw['wslDistribution'] as String?,
      sessionId: raw['sessionId'] as String?,
      title: raw['title'] as String?,
    );
  }
}
