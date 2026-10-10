import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefused;
import 'package:karmashala_ui/dialogs.dart';

import '../../workflows/application/workflows_state.dart';
import '../application/automation_providers.dart';
import '../application/automation_runs_page.dart';

/// Starts [automation] now through the server — gated like any run — and
/// says how it went, with a way to follow it in Runs.
Future<AutomationRun?> runAutomationNow(
  BuildContext context,
  WidgetRef ref,
  Automation automation,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final run = await ref.read(automationsDataProvider).runNow(automation.id);
    final said = switch (run.state) {
      AutomationRunState.running => 'Started ${automation.name}.',
      AutomationRunState.queued =>
        '${automation.name} is waiting for its checkout.',
      AutomationRunState.finished => 'Ran ${automation.name}.',
      _ => '${automation.name} did not start: ${run.reason}',
    };
    messenger?.showSnackBar(
      SnackBar(
        content: Text(said),
        action: SnackBarAction(
          label: 'See it in Runs',
          onPressed: () => showRunsOf(ref, automation.id),
        ),
      ),
    );
    return run;
  } on DataRefused catch (refused) {
    messenger?.showSnackBar(SnackBar(content: Text(refused.message)));
  } on Object catch (error) {
    messenger?.showSnackBar(
      SnackBar(content: Text('${automation.name} did not start: $error')),
    );
  }
  return null;
}

/// The Runs list, showing only [automationId]'s.
void showRunsOf(WidgetRef ref, String? automationId) {
  ref.read(runsFilterProvider.notifier).only(automationId);
  ref.read(workflowsSectionProvider.notifier).show(WorkflowsSection.runs);
}

/// Stops [run] once a person says so: a waiting one is let go, a running
/// one's session is ended.
Future<void> cancelAutomationRun(
  BuildContext context,
  WidgetRef ref,
  AutomationRun run,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final confirmed = await showConfirmDialog(
    context,
    title: 'Cancel this run?',
    message: switch (run.state) {
      AutomationRunState.queued => 'It has not started yet, and will not.',
      AutomationRunState.running =>
        'Its session is ended now. What it already changed stays until you '
            'undo the run.',
      _ =>
        'Its checks are stopped now, with everything they started, and '
            'recorded as cancelled.',
    },
    confirmLabel: 'Cancel run',
    destructive: true,
  );
  if (!confirmed) return;
  try {
    await ref.read(automationsDataProvider).cancelRun(run.id);
  } on DataRefused catch (refused) {
    messenger?.showSnackBar(SnackBar(content: Text(refused.message)));
  }
}
