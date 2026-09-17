import 'package:agent_cli/descriptors.dart';

/// The variable an agent is told its Karmashala session id through — inherited
/// by the MCP bridge it spawns, so the parent chain is the process tree's.
const String kSessionIdEnvironmentVariable = 'KARMASHALA_SESSION_ID';

/// A **port base** derived from that session id, so two sessions do not both
/// bind 8080. A **namespace, not a lock**: nothing reserves or checks a port.
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

/// A deterministic port base for [sessionId], hashed here rather than with
/// `sessionId.hashCode`, which Dart does not promise is stable across runs.
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

/// A pane that runs an agent CLI rather than a shell. [executable] and
/// [workingDirectory] are in the **target** environment, not the host's.
class AgentPaneLaunch {
  const AgentPaneLaunch({
    required this.agentId,
    required this.executable,
    this.arguments = const [],
    this.mcpArguments = const [],
    this.environment = const {},
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

  /// The **volatile** arguments: this run's MCP flags. Never stored — a
  /// restored pane that replayed yesterday's made the agent refuse to start.
  final List<String> mcpArguments;

  /// **Volatile** environment layered over the launched process only: the
  /// switch that stops the agent updating itself (Claude Code's
  /// `DISABLE_AUTOUPDATER`). Never stored — it is policy of *now*, re-derived
  /// each launch from the setting, exactly like [mcpArguments].
  final Map<String, String> environment;

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
  /// unresolvable, or a restored agent pane would come back as PowerShell.
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
        environment: environment,
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

  /// Rebuilds a launch from stored JSON, or `null` when the record is not ours.
  /// [mcpArguments] always comes back empty; the pane is armed again at start.
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
