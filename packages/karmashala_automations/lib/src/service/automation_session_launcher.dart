import 'package:agent_cli/discovery.dart';
import 'package:karmashala_git/repositories.dart';

import '../domain/automation.dart';

/// Starts the agent an automation runs: a new session in [repository] on
/// [installation], told the automation's prompt, under its permission mode.
abstract interface class AutomationSessionLauncher {
  /// The new session's id. Throws with the reason when it could not start.
  Future<String> launch(
    Automation automation,
    Repository repository,
    AgentInstallation installation,
  );
}
