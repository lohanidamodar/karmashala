import 'package:agent_cli/process.dart';

/// The kind of shell a terminal launches (in a host ConPTY).
enum TerminalShell {
  powerShell,
  commandPrompt,
  wsl,

  /// A shell on a POSIX host — zsh, bash, fish. Which one is in
  /// [TerminalProfile.posixShellPath]; there is no fixed set of them the way
  /// there is on Windows, because the answer is whatever the machine has.
  posix,

  /// An interactive shell or tmux session on a remote SSH host.
  ssh,
}

/// A launchable terminal shell: a PowerShell or Command Prompt on the Windows
/// host, a shell in a specific WSL distribution, a shell on macOS or Linux, or
/// an interactive session on an SSH host. Identified by a stable [id]
/// (`powershell`, `wsl:<distro>`, `posix:/bin/zsh`, `ssh:<hostId>`) so it can
/// be stored as the user's default-terminal preference.
class TerminalProfile {
  const TerminalProfile({
    required this.id,
    required this.label,
    required this.shell,
    this.wslDistribution,
    this.posixShellPath,
    this.sshHostId,
  });

  final String id;
  final String label;
  final TerminalShell shell;

  /// For [TerminalShell.wsl], the distribution to launch; otherwise `null`.
  final String? wslDistribution;

  /// For [TerminalShell.posix], the absolute path of the shell to launch.
  final String? posixShellPath;

  /// For [TerminalShell.ssh], the saved SSH host id.
  final String? sshHostId;

  static const powerShellId = 'powershell';
  static const commandPromptId = 'cmd';
  static String wslId(String distro) => 'wsl:$distro';
  static String posixId(String path) => 'posix:$path';
  static String sshId(String hostId) => 'ssh:$hostId';

  /// A profile for the shell at [path]. Labelled by its name, which is what a
  /// person calls it — `/bin/zsh` is "zsh".
  static TerminalProfile posix(String path, {bool isLoginShell = false}) {
    final name = path.split('/').last;
    return TerminalProfile(
      id: posixId(path),
      label: isLoginShell ? '$name (login shell)' : name,
      shell: TerminalShell.posix,
      posixShellPath: path,
    );
  }

  static TerminalProfile ssh(String hostId, {String? hostName}) =>
      TerminalProfile(
        id: sshId(hostId),
        label: hostName != null ? 'SSH: $hostName' : 'SSH: $hostId',
        shell: TerminalShell.ssh,
        sshHostId: hostId,
      );

  static const powerShell = TerminalProfile(
    id: powerShellId,
    label: 'PowerShell',
    shell: TerminalShell.powerShell,
  );

  static const commandPrompt = TerminalProfile(
    id: commandPromptId,
    label: 'Command Prompt',
    shell: TerminalShell.commandPrompt,
  );

  @override
  bool operator ==(Object other) =>
      other is TerminalProfile &&
      other.id == id &&
      other.label == label &&
      other.shell == shell &&
      other.wslDistribution == wslDistribution &&
      other.posixShellPath == posixShellPath &&
      other.sshHostId == sshHostId;

  @override
  int get hashCode => Object.hash(
    id,
    label,
    shell,
    wslDistribution,
    posixShellPath,
    sshHostId,
  );
}

/// The terminal profiles available on this machine: on Windows the two host
/// shells plus one per discovered WSL distribution; on macOS and Linux the
/// shells in [shells] with the login shell first — offering PowerShell anyway
/// gave a Mac a settings page listing two shells it could not launch.
///
/// [hostIsWindows] is passed rather than read, so this stays pure and the tests
/// can ask for either host.
List<TerminalProfile> terminalProfilesFor(
  List<ExecutionEnvironment> environments, {
  bool hostIsWindows = true,
  String? loginShell,
  List<String> shells = const [],
}) {
  if (!hostIsWindows) {
    // The login shell leads, listed or not. `chsh` validates against
    // /etc/shells, but a shell can be set by other means and the one the user
    // is actually in must never be the one missing from the list.
    final ordered = <String>[
      ?loginShell,
      for (final shell in shells)
        if (shell != loginShell) shell,
    ];
    return [
      for (final shell in ordered)
        TerminalProfile.posix(shell, isLoginShell: shell == loginShell),
      // A machine whose /etc/shells could not be read still gets something
      // launchable rather than an empty picker.
      if (ordered.isEmpty) TerminalProfile.posix(loginShell ?? '/bin/sh'),
    ];
  }
  final profiles = <TerminalProfile>[
    TerminalProfile.powerShell,
    TerminalProfile.commandPrompt,
  ];
  for (final env in environments) {
    if (env.kind == EnvironmentKind.wsl) {
      final distro = env.wslDistribution;
      if (distro == null || distro.isEmpty) continue;
      profiles.add(
        TerminalProfile(
          id: TerminalProfile.wslId(distro),
          label: '$distro (WSL)',
          shell: TerminalShell.wsl,
          wslDistribution: distro,
        ),
      );
    } else if (env.kind == EnvironmentKind.ssh) {
      final hostId = env.sshHostId;
      if (hostId == null || hostId.isEmpty) continue;
      profiles.add(
        TerminalProfile.ssh(hostId, hostName: env.name),
      );
    }
  }
  return profiles;
}

/// Rebuilds a profile from a stored [id] alone, or `null` when the id is not one
/// this app writes. Deliberately does *not* consult the discovered
/// environments: a WSL distro that has since been removed should come back as a
/// pane that fails to launch and says so, not silently as PowerShell.
TerminalProfile? terminalProfileFromId(String id) {
  if (id == TerminalProfile.powerShellId) return TerminalProfile.powerShell;
  if (id == TerminalProfile.commandPromptId) {
    return TerminalProfile.commandPrompt;
  }
  if (id.startsWith('posix:')) {
    final path = id.substring(6);
    return path.isEmpty ? null : TerminalProfile.posix(path);
  }
  if (id.startsWith('wsl:')) {
    final distro = id.substring(4);
    if (distro.isEmpty) return null;
    return TerminalProfile(
      id: id,
      label: '$distro (WSL)',
      shell: TerminalShell.wsl,
      wslDistribution: distro,
    );
  }
  if (id.startsWith('ssh:')) {
    final hostId = id.substring(4);
    if (hostId.isEmpty) return null;
    return TerminalProfile.ssh(hostId);
  }
  return null;
}

/// Resolves [id] against [profiles], falling back to the first profile when the
/// stored preference is no longer available — PowerShell on Windows, the login
/// shell elsewhere.
TerminalProfile resolveTerminalProfile(
  String? id,
  List<TerminalProfile> profiles,
) {
  for (final p in profiles) {
    if (p.id == id) return p;
  }
  return profiles.isNotEmpty ? profiles.first : TerminalProfile.powerShell;
}
