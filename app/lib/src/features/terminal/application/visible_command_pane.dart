import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/process.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'terminal_sessions_controller.dart';

/// A command the app wants to run **where the user can see it**, plus the three
/// things a `CommandRequest` does not carry: its environment, the tab label,
/// and the `agent:` id to store it under.
class VisibleCommand {
  const VisibleCommand({
    required this.agentId,
    required this.argv,
    required this.directory,
    required this.environment,
    required this.title,
  });

  /// Namespaced (`karmashala:…`) for a pane that is not an agent, so
  /// `AgentRegistry.byId` answering null is a case restore already handles.
  final String agentId;

  /// The command as argv, in the words of [environment].
  final List<String> argv;

  /// Where it runs, in that environment's own spelling.
  final EnvironmentPath directory;

  final ExecutionEnvironment environment;

  /// The tab label.
  final String title;
}

/// Opens a **visible pane** on [command], or null when there was nowhere
/// visible to run it. Null is never "run it quietly instead" — the caller
/// refuses in words.
typedef VisibleCommandOpener = String? Function(VisibleCommand command);

/// The one route from "the app wants to run something" to a pane: a second
/// spelling is a second chance to drop the WSL distribution or the SSH host.
final visibleCommandOpenerProvider = Provider<VisibleCommandOpener>((ref) {
  return (command) {
    final environment = command.environment;
    final opened = ref
        .read(terminalSessionsControllerProvider.notifier)
        .openAgentTab(
          AgentPaneLaunch(
            agentId: command.agentId,
            executable: command.argv.first,
            arguments: command.argv.skip(1).toList(),
            workingDirectory: command.directory.path,
            // How the pane reaches the *repository's* environment rather than
            // this host: the launch carries the destination, and the terminal
            // picks the transport from it.
            wslDistribution: environment.kind == EnvironmentKind.wsl
                ? environment.wslDistribution
                : null,
            sshHostId: environment.kind == EnvironmentKind.ssh
                ? environment.sshHostId
                : null,
            title: command.title,
          ),
        );
    return opened.paneId;
  };
});
