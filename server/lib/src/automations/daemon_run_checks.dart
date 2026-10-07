import 'package:karmashala_automations/check_runner.dart';
import 'package:karmashala_automations/records.dart';
import 'package:karmashala_automations/runner.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_session/session.dart';

import 'daemon_checkout_facts.dart';

/// A settled run's project checks: run by the server — in sessions it owns
/// when the checkout is on this machine, as commands over its own connection
/// on an SSH box — and recorded as not run, inconclusive, with the reason
/// anywhere else. Then its tell and notify steps.
class DaemonRunChecks {
  DaemonRunChecks({
    required this.checks,
    required this.facts,
    required this.automations,
    required this.sessionOf,
    this.followUps,
  });

  final ProjectCheckRunner checks;
  final DaemonCheckoutFacts facts;
  final AutomationRecords automations;
  final Session? Function(String sessionId) sessionOf;
  final AutomationFollowUps? followUps;

  void start(AutomationRun run) {
    void then() => followUps?.after(run);
    final automation = automations.getById(run.automationId);
    if (automation != null && !automation.steps.checks) {
      then();
      return;
    }
    final checkout = automation == null
        ? null
        : facts.repository(automation.repositoryId)?.path;
    if (checkout == null || facts.runsChecksIn(checkout)) {
      // Where the agent worked: a run in a worktree is checked there.
      final sessionId = run.sessionId;
      final worktree = sessionId == null
          ? null
          : sessionOf(sessionId)?.worktree;
      checks.start(run, directory: worktree, then: then);
      return;
    }
    checks.recordNotRun(
      run,
      'this checkout is on ${facts.describeEnvironment(checkout)}, which the '
      'Karmashala server cannot run commands in. Whether the work still '
      'stands is unknown, not proven.',
    );
    then();
  }
}
