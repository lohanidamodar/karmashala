import 'package:karmashala_automations/check_runner.dart';
import 'package:karmashala_automations/records.dart';
import 'package:karmashala_automations/runs.dart';

import 'daemon_checkout_facts.dart';

/// A settled run's project checks: run by the server — in sessions it owns
/// when the checkout is on this machine, as commands over its own connection
/// on an SSH box — and recorded as not run, inconclusive, with the reason
/// anywhere else.
class DaemonRunChecks {
  DaemonRunChecks({
    required this.checks,
    required this.facts,
    required this.automations,
  });

  final ProjectCheckRunner checks;
  final DaemonCheckoutFacts facts;
  final AutomationRecords automations;

  void start(AutomationRun run) {
    final automation = automations.getById(run.automationId);
    final checkout = automation == null
        ? null
        : facts.repository(automation.repositoryId)?.path;
    if (checkout == null || facts.runsChecksIn(checkout)) {
      checks.start(run);
      return;
    }
    checks.recordNotRun(
      run,
      'this checkout is on ${facts.describeEnvironment(checkout)}, which the '
      'Karmashala server cannot run commands in. Whether the work still '
      'stands is unknown, not proven.',
    );
  }
}
