import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';
import '../domain/agent_pane_launch.dart';
import 'terminal_sessions_controller.dart';

/// A command the app wants to run **where the user can see it**, in a named
/// environment.
///
/// The three things a pane needs that a `CommandRequest` does not carry: which
/// environment it belongs to, what to call the tab, and which `agent:` id to
/// store it under.
class VisibleCommand {
  const VisibleCommand({
    required this.agentId,
    required this.argv,
    required this.directory,
    required this.environment,
    required this.title,
  });

  /// A namespaced id for a pane that is not an agent — `karmashala:…` — so
  /// `AgentRegistry.byId` answering null for it is a case the restore path
  /// already handles.
  final String agentId;

  /// The command as argv, in the words of [environment].
  final List<String> argv;

  /// Where it runs, in that environment's own spelling.
  final EnvironmentPath directory;

  final ExecutionEnvironment environment;

  /// The tab label.
  final String title;
}

/// Opens a **visible pane** on [command] and returns its pane id, or null when
/// there was nowhere visible to run it.
///
/// Null is never "run it quietly instead": a command whose output nobody can
/// see is the failure this whole shape exists to remove, so the caller refuses
/// in words.
typedef VisibleCommandOpener = String? Function(VisibleCommand command);

/// The one route from "the app wants to run something" to a pane.
///
/// **Extracted rather than copied.** The worktree setup hook wrote this
/// lambda first and the Flutter loop needs exactly it — `flutter pub get` and
/// `flutter run` in the repository's own environment, visible. A second
/// spelling would be a second chance to drop the WSL distribution or the SSH
/// host from the launch, which is the §17 failure in a new place. Both callers
/// now read this one.
///
/// `openAgentTab` is the only route in the app that *starts* a pane on a
/// chosen command — `openTab` takes a shell profile and nothing else — and
/// going through it buys the WSL, SSH and Windows wrapping that `wrapForPty`
/// and `SshTerminalInstance` already do correctly.
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
            // Both of these are how the pane reaches the *repository's* own
            // environment rather than this host: the launch carries the
            // destination, and the terminal picks the transport from it.
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

/// The `agentId` a Flutter loop pane is opened under — `pub get`, `flutter
/// run` and the gates.
///
/// Namespaced like `kWorktreeSetupAgentId`, and for the same reason: it can
/// never collide with a registry agent, and a *restored* pane under it replays
/// nothing, because `shouldRestartOnActivate` excludes agent panes.
const String kFlutterLoopAgentId = 'karmashala:flutter';
