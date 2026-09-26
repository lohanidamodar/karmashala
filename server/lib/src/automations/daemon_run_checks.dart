import 'dart:async';

import 'package:karmashala_automations/check_runner.dart';
import 'package:karmashala_automations/records.dart';
import 'package:karmashala_automations/runs.dart';

import '../protocol/messages.dart';
import 'automation_app_relay.dart';
import 'daemon_checkout_facts.dart';

/// A settled run's project checks: run in sessions this host owns when its
/// checkout is on this machine, forwarded to the app when only it can run
/// there, and recorded as not run — inconclusive — when there is no app.
class DaemonRunChecks {
  DaemonRunChecks({
    required this.checks,
    required this.facts,
    required this.relay,
    required this.automations,
  });

  final ProjectCheckRunner checks;
  final DaemonCheckoutFacts facts;
  final AutomationAppRelay relay;
  final AutomationRecords automations;

  void start(AutomationRun run) {
    final automation = automations.getById(run.automationId);
    final checkout = automation == null
        ? null
        : facts.repository(automation.repositoryId)?.path;
    if (checkout == null || facts.isHostLocal(checkout)) {
      checks.start(run);
      return;
    }
    final where = facts.describeEnvironment(checkout);
    unawaited(
      relay.call(AutomationCallKind.runChecks, run.id).catchError((
        Object error,
      ) {
        checks.recordNotRun(
          run,
          'this checkout is on $where, where only the Karmashala app runs '
          'commands, and $error. Whether the work still stands is unknown, '
          'not proven.',
        );
      }),
    );
  }
}
