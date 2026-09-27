import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/records.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_automations/scheduler.dart';

import 'daemon_checkout_facts.dart';

/// A fire in the server: started here when the checkout is on this machine
/// (WSL too, from a Windows server), and recorded as `missed` with the reason
/// when it is anywhere else — an SSH box, where the server does not start
/// agents yet (slice 5d). Nothing is handed to an app: there is none to
/// hand it to (slice 5c).
class DaemonAutomationFiring implements AutomationFiring {
  DaemonAutomationFiring({
    required this.local,
    required this.facts,
    required this.automations,
    required this.now,
    required this.newId,
  });

  /// Fires a checkout on this machine: the package's runner on host ports.
  final AutomationFiring local;
  final DaemonCheckoutFacts facts;
  final AutomationRecords automations;
  final DateTime Function() now;
  final String Function() newId;

  @override
  Future<void> fire(
    Automation automation,
    DateTime scheduledFor, {
    String note = '',
    AutomationRun? queued,
  }) async {
    final checkout = facts.repository(automation.repositoryId)?.path;
    // A missing checkout is the runner's gate to refuse, in its own words.
    if (checkout == null || facts.isHostLocal(checkout)) {
      await local.fire(automation, scheduledFor, note: note, queued: queued);
      return;
    }
    final at = now();
    final missed = queued != null
        ? queued.copyWith(
            state: AutomationRunState.missed,
            reason: notStartedHere(checkout),
            finishedAt: at,
          )
        : AutomationRun(
            id: newId(),
            automationId: automation.id,
            scheduledFor: scheduledFor,
            firedAt: at,
            state: AutomationRunState.missed,
            reason: notStartedHere(checkout),
            finishedAt: at,
          );
    if (queued != null) {
      automations.updateRun(missed);
    } else {
      automations.insertRun(missed);
    }
  }

  /// Why nothing was started for a checkout at [checkout], in words.
  String notStartedHere(EnvironmentPath checkout) {
    final where = facts.describeEnvironment(checkout);
    return facts.isSsh(checkout)
        ? 'This checkout is on $where, an SSH machine; Karmashala does not '
              'start agents there yet, so nothing was started. Run it there '
              'by hand if you still want it.'
        : 'This checkout is on $where, which this Karmashala server cannot '
              'start agents in, so nothing was started.';
  }
}
