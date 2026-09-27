import 'package:agent_cli/descriptors.dart';

import 'automation.dart';
import 'automation_trigger.dart';

/// The event [report] is, given the status last witnessed before it — or
/// null. Moved out of the app (slice 5c): the server witnesses statuses now.
///
/// Stricter than the notification policy on purpose: a turn only *finished*
/// if it was seen working or waiting first, and a report carrying a session
/// ending (`SessionEnd` — a `/clear`, a `/resume`, a quit) is never a turn.
AutomationEventKind? automationEventOf(
  AgentActivityStatus? previous,
  AgentStatusReport report,
) {
  if (report.ending != null) return null;
  if (previous == null || previous == AgentActivityStatus.unknown) return null;
  if (previous == report.status) return null;
  return switch (report.status) {
    AgentActivityStatus.idle
        when previous == AgentActivityStatus.working ||
            previous == AgentActivityStatus.awaitingApproval =>
      AutomationEventKind.turnFinished,
    AgentActivityStatus.failed => AutomationEventKind.turnFailed,
    _ => null,
  };
}

/// What an event rule types: its prompt, with who sent it on the same line
/// so the agent and the person reading the pane both know it was not typed.
String automationMessage(Automation rule) =>
    '[from the Karmashala automation "${rule.name}"] ${rule.prompt}';
