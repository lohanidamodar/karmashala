import 'package:flutter/material.dart';
import 'package:karmashala_automations/automations.dart'
    show AutomationStepOutcome;
import 'package:karmashala_automations/checks.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_core/verdicts.dart';
import 'package:karmashala_ui/tokens.dart';

/// How a run went, in one or two words, its checks included: an agent that
/// finished with a failing check did not succeed.
enum RunOutcome {
  succeeded('Succeeded'),
  failed('Failed'),
  checking('Checking'),
  running('Running'),

  /// Its agent is done, and a pipeline it started carries on.
  waitingOnPipeline('Waiting on pipeline'),
  queued('Waiting'),
  missed('Missed'),
  planned('Would run'),
  unknown('Unknown');

  const RunOutcome(this.label);

  final String label;
}

RunOutcome runOutcome(AutomationRun run, List<AutomationCheckVerdict> checks) =>
    switch (run.state) {
      AutomationRunState.queued => RunOutcome.queued,
      AutomationRunState.running => RunOutcome.running,
      AutomationRunState.failed => RunOutcome.failed,
      AutomationRunState.missed => RunOutcome.missed,
      AutomationRunState.unrecognised => RunOutcome.unknown,
      AutomationRunState.finished =>
        checks.any((c) => c.verdict != VerificationVerdict.pass)
            ? RunOutcome.failed
            : run.stepResults.any(
                (s) => s.outcome == AutomationStepOutcome.waiting,
              )
            ? RunOutcome.waitingOnPipeline
            : run.checksObservedAt == null && checks.isEmpty
            ? RunOutcome.checking
            : RunOutcome.succeeded,
    };

String runStatusWords(AutomationRun run, List<AutomationCheckVerdict> checks) =>
    runOutcome(run, checks).label;

Color runOutcomeColor(BuildContext context, RunOutcome outcome) {
  final semantic = SemanticColors.of(context);
  return switch (outcome) {
    RunOutcome.succeeded => semantic.idle,
    RunOutcome.failed => semantic.failure,
    RunOutcome.running ||
    RunOutcome.checking ||
    RunOutcome.waitingOnPipeline => semantic.working,
    RunOutcome.missed => semantic.attention,
    RunOutcome.queued ||
    RunOutcome.unknown ||
    RunOutcome.planned => semantic.neutral,
  };
}

/// A run's outcome as a small coloured label; the word carries it, never the
/// colour alone.
class RunOutcomeChip extends StatelessWidget {
  const RunOutcomeChip({required this.outcome, super.key});

  final RunOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final color = runOutcomeColor(context, outcome);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: StateLayers.selectedAlpha),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.sm,
          vertical: Insets.xxs,
        ),
        child: Text(
          outcome.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
        ),
      ),
    );
  }
}
