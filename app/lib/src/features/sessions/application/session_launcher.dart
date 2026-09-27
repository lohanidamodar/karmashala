import 'package:path/path.dart' as p;
import 'package:riverpod/riverpod.dart';
import 'package:xterm2/xterm.dart';

import 'package:karmashala_core/logging.dart';
import '../../../core/util/agent_cli_bridge.dart';
import '../../agents/application/agent_installations_controller.dart';
import '../../agents/application/agent_providers.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SessionStartSpec, SessionStarted;
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import '../../environments/application/environment_providers.dart';
import 'package:agent_cli/process.dart';
import '../../settings/application/settings_controller.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/launch.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_core/grid.dart';
import 'package:karmashala_terminal_runtime/screen_reading.dart';
import 'package:karmashala_agent_reporting/status.dart'
    show TerminalGridStatusSource;
import 'package:karmashala_agent_status/karmashala_agent_status.dart'
    show PermissionCycleOutcome, cyclePermissionTo, kPermissionCycleSettle;
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala_session/resume.dart';
import '../data/sessions_client.dart';
import 'host_lifecycle/host_lifecycle_providers.dart';
import 'session_launch_exceptions.dart';
import 'pending_live_switches.dart';
import 'session_notice.dart';
import 'session_providers.dart';
import 'session_status_providers.dart';
import 'session_ui_providers.dart';

// The refusals are a library of their own — they carry no state, only words —
// and are re-exported here because every caller reaches for them here.
export 'session_launch_exceptions.dart';

// A pure function of a descriptor and a set of choices, reached through the
// launcher.
export 'package:karmashala_session/launch.dart'
    show agentMcpArguments, agentPaneArguments;

// The one bound on a permission cycle's redraw, the host's and the app's.
export 'package:karmashala_agent_status/karmashala_agent_status.dart'
    show kPermissionCycleSettle;

// The launcher's body, one `part` per concern, because privacy in Dart is per
// library.
part 'session_launcher_permission_live.dart';
part 'session_launcher_start.dart';
part 'session_launcher_executable.dart';
part 'session_launcher_resume_guards.dart';
part 'session_launcher_policy.dart';
part 'session_launcher_input.dart';
part 'session_launcher_hosted.dart';

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

final _log = AppLogger.named('sessions.launch');

/// **The client of the one launch path** (slice 5b): a session is started by
/// the server — [launch] asks it and shows what it started — and this is
/// where a running one is found on screen, typed into, and has its mode and
/// model chosen.
class SessionLauncher {
  SessionLauncher(this._ref);

  final Ref _ref;

  /// Sessions this launcher asked the server to end, not yet reported ended
  /// by its feed: nothing attaches to one of them in the meantime.
  final Set<String> _endingOnHost = {};

  /// The single default-installation resolution, as the New-session dialog
  /// shows it (the server applies the same rule to an agent's request).
  AgentInstallation? defaultInstallationIn(String environmentId) {
    final installs = _ref
        .read(agentInstallationsDataProvider)
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

  /// Asks the server to start [request] and shows it. The body is `_launch`,
  /// because two test doubles override this by subclassing.
  Future<SessionLaunchResult> launch(
    SessionLaunchRequest request, {
    SystemTerminal? externalTerminal,
  }) => _launch(request, externalTerminal: externalTerminal);

  /// How deep a child of [parentSessionId] would be — for a surface that says
  /// so before asking; the server applies the cap.
  SessionDepth depthForChildOf(String? parentSessionId) =>
      SessionDepth.forChildOf(
        parentSessionId,
        _ref.read(sessionsDataProvider).parentOf,
      );

  void _publish(SessionChange change) =>
      _ref.read(sessionsRevisionProvider.notifier).changed(change);
}

final sessionLauncherProvider = Provider<SessionLauncher>(
  (ref) => SessionLauncher(ref),
);
