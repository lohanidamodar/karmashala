import 'package:agent_cli/descriptors.dart';

/// The environment variable an agent running in one of our panes is told its
/// Karmashala session id through.
///
/// It is how a session an agent creates finds its parent: the MCP bridge is
/// spawned as a child of the agent CLI, inherits this and forwards it with
/// every tool call, so the parent chain is a property of the process tree we
/// built rather than of an argument the model writes — which is what the
/// recursion cap rests on.
const String kSessionIdEnvironmentVariable = 'KARMASHALA_SESSION_ID';

/// The environment variable carrying a **port base** derived from that session
/// id, so two sessions running the same repository's scripts at once do not
/// both bind 8080.
///
/// It is a **namespace, not a lock**: nothing here reserves a port, checks
/// whether one is free, or notices a collision — a repository's own scripts opt
/// in by reading the variable. What it buys is that N *different* sessions
/// almost always get N different numbers, deterministically, and that the
/// number survives a restart because it is a function of the id and nothing
/// else.
const String kSessionPortBaseEnvironmentVariable = 'KARMASHALA_PORT_BASE';

/// The lowest port [sessionPortBase] will hand out. 20000 sits below **both**
/// default ephemeral ranges — Linux starts at 32768, Windows at 49152 — so a
/// derived port is never one the OS may already have given out.
const int kSessionPortBaseFloor = 20000;

/// How many ports each session's base reserves *by convention*. Ten, so a
/// repository wanting a dev server, a database and a mock API can say
/// `base + 1`, `base + 2` without stepping on the next session.
const int kSessionPortsPerSession = 10;

/// How many distinct bases exist: `(32760 - 20000) / 10`.
const int kSessionPortBaseSlots = 1276;

/// A deterministic port base for [sessionId], in
/// `[kSessionPortBaseFloor, 32760)` and always a multiple of
/// [kSessionPortsPerSession].
///
/// **It can collide, and is not allowed to pretend otherwise**: with 1276
/// slots, ten sessions running at once have roughly a 3.5% chance that some two
/// share a base. That is the price of being a pure function of the id, which is
/// what makes the number survive a restart and a session resumed tomorrow.
///
/// The hash is written out rather than taken from `sessionId.hashCode`: Dart
/// does not promise that is stable across runs or versions.
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
/// The executable and arguments are resolved from the agent's registry
/// descriptor and its installation, and nothing here knows which agent it is
/// beyond [agentId]. [executable], [arguments] and [workingDirectory] are all
/// expressed in the **target** environment — Linux-side values wrapped in
/// `wsl.exe` when [wslDistribution] is set, Windows-side otherwise.
class AgentPaneLaunch {
  const AgentPaneLaunch({
    required this.agentId,
    required this.executable,
    this.arguments = const [],
    this.mcpArguments = const [],
    this.workingDirectory,
    this.wslDistribution,
    this.sshHostId,
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
  /// MCP endpoint. Rebuilt at every launch and never stored — every value in
  /// them dies with the app process that minted them, and a restored pane that
  /// replayed yesterday's made the agent refuse to start at all.
  final List<String> mcpArguments;

  /// The command line as it is actually run: the volatile flags, then the
  /// durable ones. MCP first, because Codex's `-c` is a global option and its
  /// resume is a *subcommand* — everything global has to be left of it.
  List<String> get commandArguments => [...mcpArguments, ...arguments];

  /// Directory the agent starts in, in its own environment.
  final String? workingDirectory;

  /// The WSL distribution to wrap the launch in, or `null` for a Windows-native
  /// (or already-POSIX host) launch.
  final String? wslDistribution;

  /// The remote SSH host id to run the launch on, or `null` for a local
  /// (Windows/WSL/POSIX) launch.
  final String? sshHostId;

  /// The `sessions` row this pane belongs to, when it has one.
  final String? sessionId;

  /// The tab label. Defaults to the agent id when absent.
  final String? title;

  /// The profile id a pane running this launch is stored under. Deliberately
  /// not resolvable through [terminalProfileFromId]: an agent pane is restored
  /// from its recorded launch, and a synthetic id that *did* resolve would
  /// silently come back as PowerShell.
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
        sshHostId: sshHostId,
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
    if (sshHostId != null) 'sshHostId': sshHostId,
    if (sessionId != null) 'sessionId': sessionId,
    if (title != null) 'title': title,
  };

  /// Rebuilds a launch from stored JSON, or `null` when the record is not one
  /// this code wrote. Forgiving on purpose: a pane that cannot be read back is
  /// dropped, never thrown on. Always comes back with [mcpArguments] empty —
  /// the pane is armed again when it starts, from the server running then.
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
    // them inside `arguments`. See [AgentMcpSupport.withoutArgumentsIn].
    final mcp =
        AgentRegistry.builtIn.byId(agentId)?.launch.mcp ??
        const AgentMcpSupport.unsupported();
    return AgentPaneLaunch(
      agentId: agentId,
      executable: executable,
      arguments: mcp.withoutArgumentsIn(stored),
      workingDirectory: raw['workingDirectory'] as String?,
      wslDistribution: raw['wslDistribution'] as String?,
      sshHostId: raw['sshHostId'] as String?,
      sessionId: raw['sessionId'] as String?,
      title: raw['title'] as String?,
    );
  }
}
