import 'package:karmashala_launch/karmashala_launch.dart';

import 'flutter_values.dart' show hostedRunSessionId;

// Terminals the server runs (slice 5a): every local and WSL shell and agent
// pane is a PTY in the server's registry. A client names what to start — a
// profile, or an agent launch — and the server builds the argv on its own OS,
// with its own environment vault; the client attaches to the session by id.

/// The session a pane runs in on the server: an agent pane's is its session
/// row's (`karmashala_<sessionId>`, the lifecycle's own id), every other
/// pane's is [hostedRunSessionId] of its pane id (`karmashala_local_<pane>`),
/// the rule hosted runs and worktree setups already share — so a restored
/// layout finds its sessions again by pane id alone.
String terminalSessionId({required String paneId, String? agentSessionId}) =>
    agentSessionId != null
    ? 'karmashala_$agentSessionId'.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')
    : hostedRunSessionId(paneId);

/// The pane a shell's session [sessionId] was opened by — the inverse of
/// [terminalSessionId] for a pane with no agent, here or on an SSH box (slice
/// 5d) — so reattaching means opening a pane under that id again. Null for
/// an agent's session, which carries its row's id.
String? paneIdOfTerminalSession(String sessionId) {
  const prefix = 'karmashala_local_';
  if (!sessionId.startsWith(prefix)) return null;
  final paneId = sessionId.substring(prefix.length);
  return paneId.isEmpty ? null : paneId;
}

Map<String, Object?> terminalProfileToJson(TerminalProfile profile) => {
  'id': profile.id,
  'label': profile.label,
  'shell': profile.shell.name,
  'wslDistribution': ?profile.wslDistribution,
  'posixShellPath': ?profile.posixShellPath,
  'sshHostId': ?profile.sshHostId,
};

TerminalProfile terminalProfileFromJson(Map<String, Object?> json) {
  final shell = TerminalShell.values.where((s) => s.name == json['shell']);
  if (shell.isEmpty) throw const FormatException('not a terminal shell');
  return TerminalProfile(
    id: json['id']! as String,
    label: json['label']! as String,
    shell: shell.single,
    wslDistribution: json['wslDistribution'] as String?,
    posixShellPath: json['posixShellPath'] as String?,
    sshHostId: json['sshHostId'] as String?,
  );
}

/// An agent launch **for one start**, as a client hands it to the server:
/// the stored intent ([AgentPaneLaunch.toJson]) plus what is volatile — this
/// run's MCP flags, the self-update switch and the names withheld. Never
/// stored, and never carrying a vault value: the server adds those.
Map<String, Object?> agentLaunchToWire(AgentPaneLaunch launch) => {
  ...launch.toJson(),
  'mcpArguments': launch.mcpArguments,
  'environment': launch.environment,
  'removedEnvironment': launch.removedEnvironment.toList()..sort(),
};

AgentPaneLaunch agentLaunchFromWire(Map<String, Object?> json) {
  final stored = AgentPaneLaunch.fromJson(json);
  if (stored == null) throw const FormatException('not an agent launch');
  final environment = json['environment'];
  final removed = json['removedEnvironment'];
  final mcp = json['mcpArguments'];
  return AgentPaneLaunch(
    agentId: stored.agentId,
    executable: stored.executable,
    arguments: stored.arguments,
    mcpArguments: [
      if (mcp is List)
        for (final argument in mcp)
          if (argument is String) argument,
    ],
    environment: {
      if (environment is Map)
        for (final entry in environment.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
    },
    removedEnvironment: {
      if (removed is List)
        for (final name in removed)
          if (name is String) name,
    },
    workingDirectory: stored.workingDirectory,
    wslDistribution: stored.wslDistribution,
    sshHostId: stored.sshHostId,
    sessionId: stored.sessionId,
    title: stored.title,
  );
}

/// What `terminals.open` answers: the session to attach to, and what the
/// server decided about it.
final class TerminalOpened {
  const TerminalOpened({
    required this.sessionId,
    required this.paneId,
    required this.title,
    required this.profileId,
    required this.shellIntegration,
    this.adopted = false,
  });

  final String sessionId;
  final String paneId;
  final String title;
  final String profileId;

  /// Whether the launch carries the OSC 133 bootstrap, so the pane records
  /// command blocks off its markers.
  final bool shellIntegration;

  /// The session was already running under this pane's id — a pane opened
  /// again after its client restarted — and nothing new was started.
  final bool adopted;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'paneId': paneId,
    'title': title,
    'profileId': profileId,
    'shellIntegration': shellIntegration,
    'adopted': adopted,
  };

  static TerminalOpened fromJson(Map<String, Object?> json) => TerminalOpened(
    sessionId: json['sessionId']! as String,
    paneId: json['paneId']! as String,
    title: json['title']! as String,
    profileId: json['profileId']! as String,
    shellIntegration: json['shellIntegration'] == true,
    adopted: json['adopted'] == true,
  );
}

/// One terminal the server runs, or ran and still keeps the record of, as
/// its own copy of the screen reads it: the title the program set (or the
/// one a person gave it), the directory the shell last reported (OSC 7), the
/// last command it ran (OSC 133) and how that ended.
final class TerminalRecord {
  const TerminalRecord({
    required this.sessionId,
    required this.paneId,
    required this.profileId,
    required this.title,
    required this.startedAt,
    this.environmentId,
    this.shellIntegration = false,
    this.workingDirectory,
    this.lastCommand,
    this.lastCommandExitCode,
    this.endedAt,
    this.exitCode,
    this.endReason,
  });

  final String sessionId;
  final String paneId;
  final String profileId;
  final String? environmentId;

  /// Whether its launch carries OSC 133 shell integration, so a pane that
  /// attaches later records command blocks off its markers.
  final bool shellIntegration;
  final String title;
  final String? workingDirectory;
  final String? lastCommand;
  final int? lastCommandExitCode;
  final DateTime startedAt;

  /// Null while the process runs.
  final DateTime? endedAt;

  /// Null on a terminal still running, and on one that ended with no code
  /// ([endReason] says why).
  final int? exitCode;
  final String? endReason;

  bool get isLive => endedAt == null;

  TerminalRecord copyWith({
    String? title,
    String? workingDirectory,
    String? lastCommand,
    int? lastCommandExitCode,
    bool clearLastCommandExit = false,
    DateTime? endedAt,
    int? exitCode,
    String? endReason,
  }) => TerminalRecord(
    sessionId: sessionId,
    paneId: paneId,
    profileId: profileId,
    environmentId: environmentId,
    shellIntegration: shellIntegration,
    title: title ?? this.title,
    workingDirectory: workingDirectory ?? this.workingDirectory,
    lastCommand: lastCommand ?? this.lastCommand,
    lastCommandExitCode: clearLastCommandExit
        ? null
        : lastCommandExitCode ?? this.lastCommandExitCode,
    startedAt: startedAt,
    endedAt: endedAt ?? this.endedAt,
    exitCode: exitCode ?? this.exitCode,
    endReason: endReason ?? this.endReason,
  );

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'paneId': paneId,
    'profileId': profileId,
    'environmentId': ?environmentId,
    'shellIntegration': shellIntegration,
    'title': title,
    'workingDirectory': ?workingDirectory,
    'lastCommand': ?lastCommand,
    'lastCommandExitCode': ?lastCommandExitCode,
    'startedAt': startedAt.toUtc().toIso8601String(),
    if (endedAt != null) 'endedAt': endedAt!.toUtc().toIso8601String(),
    'exitCode': ?exitCode,
    'endReason': ?endReason,
  };

  static TerminalRecord fromJson(Map<String, Object?> json) => TerminalRecord(
    sessionId: json['sessionId']! as String,
    paneId: json['paneId']! as String,
    profileId: json['profileId']! as String,
    environmentId: json['environmentId'] as String?,
    shellIntegration: json['shellIntegration'] == true,
    title: json['title']! as String,
    workingDirectory: json['workingDirectory'] as String?,
    lastCommand: json['lastCommand'] as String?,
    lastCommandExitCode: json['lastCommandExitCode'] as int?,
    startedAt: DateTime.parse(json['startedAt']! as String).toUtc(),
    endedAt: json['endedAt'] == null
        ? null
        : DateTime.parse(json['endedAt']! as String).toUtc(),
    exitCode: json['exitCode'] as int?,
    endReason: json['endReason'] as String?,
  );
}
