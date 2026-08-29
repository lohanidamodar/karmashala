import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/execution_environment.dart';

/// The kind of shell a terminal launches (in a host ConPTY).
enum TerminalShell { powerShell, commandPrompt, wsl }

/// A launchable terminal shell: a PowerShell/Command Prompt on the Windows host,
/// or an interactive shell in a specific WSL distribution (via `wsl.exe -d`).
///
/// Identified by a stable [id] (`powershell`, `cmd`, `wsl:<distro>`) so it can be
/// stored as the user's default-terminal preference.
class TerminalProfile {
  const TerminalProfile({
    required this.id,
    required this.label,
    required this.shell,
    this.wslDistribution,
  });

  final String id;
  final String label;
  final TerminalShell shell;

  /// For [TerminalShell.wsl], the distribution to launch; otherwise `null`.
  final String? wslDistribution;

  static const powerShellId = 'powershell';
  static const commandPromptId = 'cmd';
  static String wslId(String distro) => 'wsl:$distro';

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
      other.wslDistribution == wslDistribution;

  @override
  int get hashCode => Object.hash(id, label, shell, wslDistribution);
}

/// The terminal profiles available on this machine: the two Windows-host shells
/// plus one per discovered WSL distribution.
List<TerminalProfile> terminalProfilesFor(
  List<ExecutionEnvironment> environments,
) {
  final profiles = <TerminalProfile>[
    TerminalProfile.powerShell,
    TerminalProfile.commandPrompt,
  ];
  for (final env in environments) {
    if (env.kind != EnvironmentKind.wsl) continue;
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
  }
  return profiles;
}

/// Rebuilds a profile from a stored [id] alone, or `null` when the id is not one
/// this app writes.
///
/// Restoring a workspace deliberately does *not* consult the discovered
/// environments: a WSL distro that has since been removed should come back as a
/// pane that fails to launch and says so, not silently as PowerShell.
TerminalProfile? terminalProfileFromId(String id) {
  if (id == TerminalProfile.powerShellId) return TerminalProfile.powerShell;
  if (id == TerminalProfile.commandPromptId) {
    return TerminalProfile.commandPrompt;
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
  return null;
}

/// Resolves [id] against [profiles], falling back to the first profile
/// (PowerShell) when the stored preference is no longer available.
TerminalProfile resolveTerminalProfile(
  String? id,
  List<TerminalProfile> profiles,
) {
  for (final p in profiles) {
    if (p.id == id) return p;
  }
  return profiles.isNotEmpty ? profiles.first : TerminalProfile.powerShell;
}
