import 'package:riverpod/riverpod.dart';
import 'package:xterm2/xterm.dart';

import 'package:karmashala_core/logging.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../agents/application/agent_installations_controller.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import 'package:agent_cli/read.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/application/environment_resolver.dart';
import 'package:agent_cli/process.dart';
import '../../git/application/git_providers.dart';
import '../../mcp/session_mcp.dart';
import '../../repositories/application/repository_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../terminal/data/pty_launch.dart';
import '../../terminal/data/system_terminal_service.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_core/grid.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import '../data/session_repository_dao.dart';
import '../domain/session.dart';
import '../domain/session_attribution.dart';
import '../domain/session_depth.dart';
import '../domain/session_launch.dart';
import '../domain/session_lineage.dart';
import '../domain/session_naming.dart';
import '../domain/session_model.dart';
import '../domain/session_permission.dart';
import '../domain/session_resume.dart';
import '../domain/session_status.dart';
import 'decision_recorder.dart';
import 'handoff_packet_files.dart';
import 'session_launch_arguments.dart';
import 'session_launch_exceptions.dart';
import 'session_mcp_arguments.dart';
import 'session_providers.dart';
import 'session_status_providers.dart';
import 'session_ui_providers.dart';
import 'session_working_directory.dart';

// The four refusals are a library of their own — they carry no state, only
// words — and are re-exported here because every caller reaches for them here.
export 'session_launch_exceptions.dart';

// And `agentPaneArguments`, for the same reason: a pure function of a
// descriptor and a set of choices, reached through the launcher.
export 'session_launch_arguments.dart';

// The launcher's body, one `part` per concern — start, resume_guards, policy,
// surfaces, input — because privacy in Dart is per library.
part 'session_launcher_start.dart';
part 'session_launcher_resume_guards.dart';
part 'session_launcher_policy.dart';
part 'session_launcher_surfaces.dart';
part 'session_launcher_input.dart';

/// What a launch produced.
class SessionLaunchResult {
  const SessionLaunchResult({
    required this.session,
    this.paneId,
    this.tabId,
    this.workingDirectoryNotice,
  });

  final Session session;
  final String? paneId;
  final String? tabId;

  /// Plain words for the user when the session started somewhere other than
  /// where it was recorded. Not a failure; the tree is not the one it knew.
  final String? workingDirectoryNotice;
}

/// Every launch says what it decided: four bugs here were silent by
/// construction, each a plausible session wrong only on its command line.
final _log = AppLogger.named('sessions.launch');

/// **The** way a session comes into existence. Every in-app session runs in a
/// PTY, every started session gets a row, and permission mode resolves here.
class SessionLauncher {
  SessionLauncher(this._ref);

  final Ref _ref;

  /// The single default-installation resolution. Four variants of this existed,
  /// and only some of them consulted the user's configured default at all.
  AgentInstallation? defaultInstallationIn(String environmentId) {
    final installs = _ref
        .read(agentInstallationDaoProvider)
        .getByEnvironment(environmentId);
    if (installs.isEmpty) return null;
    final settings = _ref.read(settingsControllerProvider);
    return resolveDefaultInstallation(
          installs,
          defaultInstallationId: settings.defaultAgentInstallationId,
          defaultAgentId: settings.defaultAgent,
        ) ??
        installs.first;
  }

  /// Creates the session row and starts it on the requested surface. The body
  /// is `_launch`, because two test doubles override this by subclassing.
  Future<SessionLaunchResult> launch(SessionLaunchRequest request) =>
      _launch(request);

  /// Where a depth walk reads from. Exposed so the MCP surface can check the
  /// cap before doing any work it would have to undo.
  SessionDepth depthForChildOf(String? parentSessionId) =>
      SessionDepth.forChildOf(
        parentSessionId,
        _ref.read(sessionDaoProvider).parentOf,
      );

  void _publish(SessionChange change) =>
      _ref.read(sessionsRevisionProvider.notifier).changed(change);
}

final sessionLauncherProvider = Provider<SessionLauncher>(
  (ref) => SessionLauncher(ref),
);
