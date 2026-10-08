import 'package:agent_cli/discovery.dart';
import 'package:karmashala_git/repositories.dart';

import '../domain/automation.dart';
import '../domain/github_trigger.dart';

/// Starts the agent an automation runs: a new session in [repository] on
/// [installation], told the automation's prompt, under its permission mode.
abstract interface class AutomationSessionLauncher {
  /// The new session's id. Throws with the reason when it could not start.
  /// [pullRequest] is a pull request's branch to check out in a new worktree,
  /// in place of the automation's own worktree choice.
  Future<String> launch(
    Automation automation,
    Repository repository,
    AgentInstallation installation, {
    PullRequestCheckout? pullRequest,
  });
}
