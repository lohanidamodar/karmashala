import '../../agents/domain/agent_descriptor.dart';
import '../../settings/domain/permission_mode.dart';

/// The environment variable an agent running in one of our panes is told its
/// Chitragupta session id through.
///
/// It is how a session an agent creates finds its parent: the MCP bridge is
/// spawned as a child of the agent CLI, inherits this, and forwards it with
/// every tool call. That makes the parent chain a property of the process tree
/// we built rather than of an argument the model writes, which is what the
/// recursion cap needs to be worth anything.
const String kSessionIdEnvironmentVariable = 'CHITRAGUPTA_SESSION_ID';

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
    this.workingDirectory,
    this.wslDistribution,
    this.sessionId,
    this.title,
  });

  /// `AgentDescriptor.id` — what the grid status source looks the rules up by.
  final String agentId;

  final String executable;
  final List<String> arguments;

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
  static AgentPaneLaunch? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final agentId = raw['agentId'];
    final executable = raw['executable'];
    if (agentId is! String || agentId.isEmpty) return null;
    if (executable is! String || executable.isEmpty) return null;
    return AgentPaneLaunch(
      agentId: agentId,
      executable: executable,
      arguments: [
        for (final argument in (raw['arguments'] as List?) ?? const [])
          if (argument is String) argument,
      ],
      workingDirectory: raw['workingDirectory'] as String?,
      wslDistribution: raw['wslDistribution'] as String?,
      sessionId: raw['sessionId'] as String?,
      title: raw['title'] as String?,
    );
  }
}

/// The command-line arguments for running [descriptor] **interactively**.
///
/// Deliberately not [AgentLaunchSpec.baseArguments]: those are the headless
/// protocol flags the adapters need (`--output-format stream-json`,
/// `app-server`), and passing them to a PTY launch would produce a machine
/// protocol on a human's screen. What an interactive launch does share is the
/// permission flags and the agent's *interactive* resume convention — which is
/// why the descriptor records two of those.
///
/// An agent the registry has never heard of gets no arguments at all rather than
/// another agent's flags (`PRODUCT.md` principle 5).
List<String> interactiveAgentArguments(
  AgentDescriptor? descriptor,
  PermissionMode permissionMode, {
  String? resumeSessionId,
}) => [
  ...?descriptor?.launch.permissionArgumentsFor(permissionMode),
  if (resumeSessionId != null && resumeSessionId.isNotEmpty)
    ...?descriptor?.launch.interactiveResume.argumentsFor(resumeSessionId),
];
