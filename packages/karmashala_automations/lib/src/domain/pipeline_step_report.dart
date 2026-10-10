import 'automation_steps.dart';
import 'pipeline_run.dart';

/// What a pipeline step reports of [run], the run it started: waiting while
/// it runs or holds at a gate, done once it finished, failed once it failed
/// or was stopped. A retried run goes back to waiting.
({AutomationStepOutcome outcome, String detail}) pipelineStepReport(
  PipelineRun run,
) {
  final name = run.definition.name;
  final stage = run.current?.role;
  return switch (run.state) {
    PipelineRunState.running => (
      outcome: AutomationStepOutcome.waiting,
      detail: stage == null
          ? 'Started "$name"; waiting on the pipeline.'
          : '"$name" is running $stage.',
    ),
    PipelineRunState.waiting => (
      outcome: AutomationStepOutcome.waiting,
      detail: '"$name" waits for your approval at ${stage ?? 'a gate'}.',
    ),
    PipelineRunState.finished => (
      outcome: AutomationStepOutcome.done,
      detail: '"$name" finished.',
    ),
    PipelineRunState.failed => (
      outcome: AutomationStepOutcome.failed,
      detail:
          '"$name" failed at ${stage ?? 'the start'}'
          '${run.reason == null ? '.' : ': ${run.reason}'}',
    ),
    PipelineRunState.stopped => (
      outcome: AutomationStepOutcome.failed,
      detail: '"$name" was stopped at ${stage ?? 'the start'}.',
    ),
  };
}
