part of '../agent_descriptor.dart';

/// A protocol of the agent's own that Karmashala speaks in place of ACP,
/// translated in-process so everything past the transport still sees ACP:
/// the agent's own binary and login, with what its protocol carries that
/// an ACP adapter would drop.
enum AcpNativeBridge {
  /// `codex app-server`: Codex's JSON-RPC over stdio.
  codexAppServer,

  /// Claude Code's stream-json mode: JSON lines in and out, with control
  /// requests for permissions, interrupts and settings.
  claudeStreamJson,
}

/// Argv an agent accepts from release [since] on, with where that was read.
class AcpVersionedArgument {
  const AcpVersionedArgument({
    required this.since,
    required this.arguments,
    required this.evidence,
  });

  final String since;
  final List<String> arguments;
  final String evidence;

  /// Whether the agent at [version] (as `--version` prints it) takes these.
  bool acceptedBy(String version) =>
      compareAgentVersions(version, '0.0.0') > 0 &&
      compareAgentVersions(version, since) >= 0;
}

/// A terminal CLI that gained a built-in ACP subcommand from release [since]
/// onward (e.g. `agy acp` from `agy` 1.5.0), preferred over a separate
/// standalone adapter binary when a new enough CLI is installed.
class AcpCliSubcommand {
  const AcpCliSubcommand({
    required this.binaries,
    required this.since,
    required this.arguments,
    this.terminalLogin,
    required this.evidence,
  });

  /// Binary names and Windows install locations for the terminal CLI.
  final AgentBinaries binaries;

  /// First CLI release that ships the ACP subcommand.
  final String since;

  /// Leading arguments that start ACP mode on the CLI (e.g. `['acp']`).
  final List<String> arguments;

  /// Terminal login offered when running through this CLI subcommand (e.g.
  /// `['--login']`, appended after [arguments] to run `agy acp --login`).
  final AcpTerminalLogin? terminalLogin;

  final String evidence;

  /// Whether the CLI at [version] is new enough to run [arguments].
  bool supportedBy(String version) =>
      compareAgentVersions(version, '0.0.0') > 0 &&
      compareAgentVersions(version, since) >= 0;
}

/// How one of an agent's auth methods completes, in words a login dialog
/// shows before it starts, with where that was read.
class AcpAuthCompletion {
  const AcpAuthCompletion({required this.how, required this.evidence});

  final String how;
  final String evidence;
}

/// A login the agent's own program runs in a terminal, offered beside the
/// methods it advertises over ACP: [arguments] go after whatever runs the
/// program (`-y <package>` for npx), never after its ACP mode arguments.
class AcpTerminalLogin {
  const AcpTerminalLogin({
    required this.name,
    required this.arguments,
    required this.how,
    required this.evidence,
  });

  final String name;
  final List<String> arguments;
  final String how;
  final String evidence;
}

/// How an agent is driven over the Agent Client Protocol
/// (https://agentclientprotocol.com): JSON-RPC over the process's own stdio,
/// in place of a terminal. Declared on a descriptor; a consumer asks
/// `adapter.acp != null`, never who the agent is.
class AcpLaunchSpec {
  const AcpLaunchSpec({
    this.arguments = const [],
    this.modeNames = const {},
    this.authMethodId,
    this.clientName = 'Karmashala',
    this.npxPackage,
    this.environment = const {},
    this.linuxArguments = const [],
    this.versionedArguments = const [],
    this.registryId,
    this.apiKeyVariables = const {},
    this.nativeBridge,
    this.optionModes = const {},
    this.authCompletions = const {},
    this.terminalLogin,
    this.screenedModes = const {},
    this.cliSubcommand,
  });

  /// Modes in which the agent's own reviewer decides what runs: what it still
  /// asks is the person's to answer, at any rung.
  final Set<String> screenedModes;

  /// Auth method id → how it completes, read off the agent.
  final Map<String, AcpAuthCompletion> authCompletions;

  /// The agent's own terminal login, for an agent whose ACP methods cannot
  /// show a person where to sign in (a link it opens and never prints).
  final AcpTerminalLogin? terminalLogin;

  /// Built-in ACP subcommand on the companion CLI (e.g. `agy acp`), preferred
  /// over standalone adapter binaries when a new enough CLI is present.
  final AcpCliSubcommand? cliSubcommand;

  /// Set when the agent is spoken to in its own protocol, through
  /// [arguments], and translated to ACP in-process; null for an agent that
  /// speaks ACP itself.
  final AcpNativeBridge? nativeBridge;

  /// How any ACP agent's permission request is answered: the server picks the
  /// request's own allow or reject option, so no key is typed. The same two
  /// answers the server's prompt evidence names.
  static const AgentApprovalRules permissionAnswers = AgentApprovalRules(
    approve: AgentApprovalKey(
      keys: 'allow',
      label: 'Allow',
      effect: 'Lets the agent make this call.',
    ),
    deny: AgentApprovalKey(
      keys: 'reject',
      label: 'Reject',
      effect: 'Refuses this call; the agent carries on without it.',
    ),
  );

  /// Argv that puts the binary into ACP stdio mode — `['--acp']`,
  /// `['agent', 'stdio']`, or empty for a dedicated adapter binary.
  final List<String> arguments;

  /// Argv added after [arguments] on Linux only — WSL, or a Linux host —
  /// where the registry's Linux build wants something its other builds do
  /// not (`--uid=` for Antigravity). See [argumentsFor].
  final List<String> linuxArguments;

  /// Argv a release of the agent is known to accept from a version on. An
  /// older one may refuse a flag it does not know and never start, so a
  /// version nobody read gets none of them.
  final List<AcpVersionedArgument> versionedArguments;

  /// The public ACP registry's id for this agent, when it ships there as a
  /// prebuilt archive Karmashala can install into its managed folder
  /// (`~/karmashala/acp/<registryId>/<version>/`) and find there again.
  final String? registryId;

  /// Whether [leadingArguments] launches this agent through [cliSubcommand]
  /// rather than the standalone adapter binary.
  bool isCliSubcommand(List<String> leadingArguments) {
    final sub = cliSubcommand;
    if (sub == null || leadingArguments.length != sub.arguments.length) {
      return false;
    }
    for (var i = 0; i < leadingArguments.length; i++) {
      if (leadingArguments[i] != sub.arguments[i]) return false;
    }
    return true;
  }

  /// Terminal login available for an installation with [leadingArguments]:
  /// prefers [cliSubcommand]'s own terminal login when running through it.
  AcpTerminalLogin? terminalLoginFor(List<String> leadingArguments) =>
      isCliSubcommand(leadingArguments)
      ? (cliSubcommand!.terminalLogin ?? terminalLogin)
      : terminalLogin;

  /// The mode argv for one machine: [arguments], then [linuxArguments] when
  /// [linux], then the [versionedArguments] its [version] accepts.
  List<String> argumentsFor({required bool linux, String? version}) => [
    ...arguments,
    if (linux) ...linuxArguments,
    if (version != null)
      for (final argument in versionedArguments)
        if (argument.acceptedBy(version)) ...argument.arguments,
  ];

  /// Whether an agent started in an environment of [kind] runs on Linux: a
  /// WSL distribution always, the local POSIX host when it is Linux
  /// ([hostIsLinux]) rather than macOS. An SSH box is not asked.
  static bool runsOnLinux(EnvironmentKind kind, {required bool hostIsLinux}) =>
      kind == EnvironmentKind.wsl ||
      (kind == EnvironmentKind.localPosix && hostIsLinux);

  /// Candidate agent mode ids per Karmashala rung, in the agent's own
  /// spelling, matched case-insensitively against what `session/new` offers.
  /// A rung with no entry is one the agent has no mode for.
  final Map<PermissionRisk, List<String>> modeNames;

  /// The auth method to use when the agent demands one, or null for the only
  /// one it advertises.
  final String? authMethodId;

  /// Auth method id → the environment variable that method reads its API key
  /// from, as the agent documents it.
  final Map<String, String> apiKeyVariables;

  /// This spec with [methodId] as its [authMethodId].
  AcpLaunchSpec withAuthMethod(String? methodId) => AcpLaunchSpec(
    arguments: arguments,
    modeNames: modeNames,
    authMethodId: methodId,
    clientName: clientName,
    npxPackage: npxPackage,
    environment: environment,
    linuxArguments: linuxArguments,
    versionedArguments: versionedArguments,
    registryId: registryId,
    apiKeyVariables: apiKeyVariables,
    nativeBridge: nativeBridge,
    optionModes: optionModes,
    authCompletions: authCompletions,
    terminalLogin: terminalLogin,
    screenedModes: screenedModes,
    cliSubcommand: cliSubcommand,
  );

  /// What `initialize` announces as `clientInfo.name`.
  final String clientName;

  /// The npm package `npx -y <package>` runs when no binary is installed, or
  /// null for an agent that must be installed first.
  final String? npxPackage;

  /// Variables layered over the launched process's environment — what a
  /// person-added agent's row declares. Empty for the shipped agents.
  final Map<String, String> environment;

  /// The first of [risk]'s candidates among [availableModeIds], in the
  /// agent's own spelling, or null when it offers none of them.
  String? modeFor(PermissionRisk risk, Iterable<String> availableModeIds) {
    final offered = {for (final id in availableModeIds) id.toLowerCase(): id};
    for (final candidate in modeNames[risk] ?? const <String>[]) {
      final match = offered[candidate.toLowerCase()];
      if (match != null) return match;
    }
    return null;
  }

  /// [modeFor] over the modes an agent offers, matched by id and then by
  /// name, so a person can name a mode whose id is a URL by its name.
  String? modeForOffered(
    PermissionRisk risk,
    Iterable<({String id, String name})> offered,
  ) {
    final byId = modeFor(risk, offered.map((mode) => mode.id));
    if (byId != null) return byId;
    final byName = modeFor(risk, offered.map((mode) => mode.name));
    if (byName == null) return null;
    return offered.firstWhere((mode) => mode.name == byName).id;
  }

  /// [rungOfMode] for an offered mode, read by its id and then its [name].
  PermissionRisk? rungOfOffered(String modeId, String? name) =>
      rungOfMode(modeId) ??
      (name == null || name.isEmpty ? null : rungOfMode(name));

  /// Permission option ids → the mode each one switches the agent to, for an
  /// agent whose option ids are not its mode ids. An id named nowhere here is
  /// read as a mode id itself.
  final Map<String, String> optionModes;

  /// The rung [modeId] stands for: the lowest one [modeNames] lists it under,
  /// or null for a mode this spec does not name.
  PermissionRisk? rungOfMode(String modeId) {
    final wanted = modeId.toLowerCase();
    for (final rung in PermissionRisk.values) {
      if (modeNames[rung]?.any((m) => m.toLowerCase() == wanted) ?? false) {
        return rung;
      }
    }
    return null;
  }

  /// The rung choosing permission option [optionId] would put the agent on,
  /// or null when the option switches to no mode this spec names.
  PermissionRisk? rungOfOption(String optionId) =>
      rungOfMode(optionModes[optionId] ?? optionId);
}
