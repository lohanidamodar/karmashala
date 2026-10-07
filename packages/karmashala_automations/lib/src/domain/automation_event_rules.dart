import 'package:agent_cli/descriptors.dart';

import 'automation.dart';
import 'automation_attribution.dart';
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

/// Whether [report] waits on a person: an open prompt or question, never an
/// agent idle at its own input.
bool waitsOnPerson(AgentStatusReport report) =>
    report.hasOpenPrompt || report.hasOpenQuestion;

/// [automationEventOf], with [AutomationEventKind.needsYou] when [report]
/// starts a wait [wasWaiting] did not have. A session first seen waiting is
/// not an event, as a turn first seen finished is not.
AutomationEventKind? automationEventWithWait(
  AgentActivityStatus? previous,
  AgentStatusReport report, {
  required bool wasWaiting,
}) {
  if (report.ending == null &&
      previous != null &&
      previous != AgentActivityStatus.unknown &&
      !wasWaiting &&
      waitsOnPerson(report)) {
    return AutomationEventKind.needsYou;
  }
  return automationEventOf(previous, report);
}

/// What an event rule types: its prompt, with who sent it on the same line
/// so the agent and the person reading the pane both know it was not typed.
String automationMessage(Automation rule) => AutomationAttribution(
  automationId: rule.id,
  name: rule.name,
).render(rule.prompt);
