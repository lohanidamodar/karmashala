import 'package:agent_cli/discovery.dart';
import 'package:karmashala_git/repositories.dart';

import '../domain/automation.dart';

/// Starts the agent an automation runs: a new session in [repository] on
/// [installation], told the automation's prompt, under its permission mode.
abstract interface class AutomationSessionLauncher {
  /// The new session's id. Throws with the reason when it could not start.
  /// [branch] is an existing branch to check out in a new worktree — a pull
  /// request's — in place of the automation's own worktree choice.
  Future<String> launch(
    Automation automation,
    Repository repository,
    AgentInstallation installation, {
    String? branch,
  });
}
