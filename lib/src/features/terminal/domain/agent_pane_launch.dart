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
    // them inside `arguments`, and the owner's saved workspace is full of
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
