import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/records.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_automations/scheduler.dart';

import '../protocol/messages.dart';
import 'automation_app_relay.dart';
import 'daemon_checkout_facts.dart';

/// A fire in the host: started here when the checkout is on this machine,
/// forwarded to the app when only it can start there (WSL, SSH), and recorded
/// as `missed` with the reason when there is no app to forward to.
class DaemonAutomationFiring implements AutomationFiring {
  DaemonAutomationFiring({
    required this.local,
    required this.facts,
    required this.relay,
    required this.automations,
    required this.now,
    required this.newId,
  });

  /// Fires a checkout on this machine: the package's runner on host ports.
  final AutomationFiring local;
  final DaemonCheckoutFacts facts;
  final AutomationAppRelay relay;
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
    final where = facts.describeEnvironment(checkout);
    String why;
    try {
      await relay.call(
        AutomationCallKind.fireAutomation,
        automation.id,
        note: note,
        scheduledFor: scheduledFor,
        queuedRunId: queued?.id,
      );
      return;
    } on AutomationRelayFailure catch (failure) {
      why = failure.message == kAutomationAppNotRunning
          ? 'This checkout is on $where, where only the Karmashala app starts '
                'agents, and the app was not running. Nothing was started; run '
                'it from the app if you still want it.'
          : 'This checkout is on $where, where only the Karmashala app starts '
                'agents, and it did not: ${failure.message}';
    }
    final at = now();
    final missed = queued != null
        ? queued.copyWith(
            state: AutomationRunState.missed,
            reason: why,
            finishedAt: at,
          )
        : AutomationRun(
            id: newId(),
            automationId: automation.id,
            scheduledFor: scheduledFor,
            firedAt: at,
            state: AutomationRunState.missed,
            reason: why,
            finishedAt: at,
          );
    if (queued != null) {
      automations.updateRun(missed);
    } else {
      automations.insertRun(missed);
    }
  }
}
