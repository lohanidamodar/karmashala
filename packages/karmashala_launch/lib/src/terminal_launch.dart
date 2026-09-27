import 'agent_pane_launch.dart';
import 'launch_context.dart';
import 'pty_launch.dart';
import 'shell_integration.dart';
import 'terminal_profile.dart';

/// Whether a pane launched this way gets OSC 133 shell integration: no agent
/// pane (it runs the CLI directly, so there is no prompt hook), the setting
/// on, and a shell that can emit markers — never `cmd.exe`.
bool shellIntegrationApplies({
  required TerminalProfile profile,
  required bool shellIntegration,
  required AgentPaneLaunch? agentLaunch,
}) =>
    agentLaunch == null &&
    shellIntegration &&
    shellSupportsIntegration(profile.shell);

/// One terminal's launch as the machine that starts it builds it: the argv,
/// directory and environment, and whether the shell carries the OSC 133
/// bootstrap (only a Windows host injects one — a POSIX login shell is
/// opened as it is).
class TerminalLaunch {
  const TerminalLaunch({
    required this.launch,
    required this.title,
    required this.profileId,
    required this.shellIntegration,
  });

  final PtyLaunch launch;

  /// The pane's label: the profile's, or the agent's title.
  final String title;

  /// What a restore rebuilds the pane as: the profile, or `agent:<id>`.
  final String profileId;

  /// Whether the launch carries the integration bootstrap, so a client
  /// records command blocks off its markers.
  final bool shellIntegration;
}

/// Builds [profile]'s shell — or [agentLaunch]'s agent — for the machine
/// whose OS [hostIsWindows] names: **the server's**, never a client's. The
/// one place a host OS becomes a [LaunchContext]; from here down the command
/// is spelled for where it runs. [overlay] is the server's environment vault,
/// layered over the host environment (an agent launch's own variables and
/// its session id win over it).
TerminalLaunch terminalLaunchFor({
  required TerminalProfile profile,
  AgentPaneLaunch? agentLaunch,
  String? workingDirectory,
  required bool hostIsWindows,
  String? posixShell,
  bool shellIntegration = false,
  Map<String, String> overlay = const {},
}) {
  if (agentLaunch != null) {
    return TerminalLaunch(
      launch: agentPtyLaunchFor(
        agentLaunch,
        context: LaunchContext.forAgent(
          agentLaunch,
          hostIsWindows: hostIsWindows,
        ),
        environment: overlay,
      ),
      title: agentLaunch.title ?? agentLaunch.agentId,
      profileId: agentLaunch.profileId,
      shellIntegration: false,
    );
  }
  final integrate = shellIntegrationApplies(
    profile: profile,
    shellIntegration: shellIntegration,
    agentLaunch: null,
  );
  return TerminalLaunch(
    launch: ptyLaunchFor(
      profile,
      context: LaunchContext.forProfile(
        profile,
        hostIsWindows: hostIsWindows,
        posixShell: posixShell,
      ),
      workingDirectory: workingDirectory,
      shellIntegration: integrate,
      environment: overlay,
    ),
    title: profile.label,
    profileId: profile.id,
    // Off Windows the launch carries no bootstrap, so there are no markers.
    shellIntegration: integrate && hostIsWindows,
  );
}
