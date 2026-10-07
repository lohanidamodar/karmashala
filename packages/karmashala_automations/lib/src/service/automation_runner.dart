import '../domain/automation.dart';
import '../domain/automation_run.dart';
import '../domain/github_trigger.dart';
import 'automation_records.dart';
import 'automation_firing.dart';
import 'automation_session_launcher.dart';
import 'checkout_facts.dart';
import 'run_base_checkpoint.dart';
import 'unattended_preflight.dart';

/// Firing an automation: the gate again, a checkpoint of the base, a session.
/// A refusal is a recorded `failed` run — a silent skip would repeat forever.
class AutomationRunner implements AutomationFiring {
  AutomationRunner({
    required AutomationRecords automations,
    required this._preflight,
    required this._facts,
    required this._checkpoints,
    required this._launcher,
    required this._now,
    required this._newId,
    void Function()? onChanged,
  }) : _dao = automations,
       _onChanged = onChanged ?? _nothing;

  final AutomationRecords _dao;
  final UnattendedPreflight _preflight;
  final CheckoutFacts _facts;
  final RunBaseCheckpoint _checkpoints;
  final AutomationSessionLauncher _launcher;
  final DateTime Function() _now;
  final String Function() _newId;
  final void Function() _onChanged;

  static void _nothing() {}

  @override
  Future<void> fire(
    Automation automation,
    DateTime scheduledFor, {
    String note = '',
    AutomationRun? queued,
  }) => start(automation, scheduledFor, note: note, queued: queued);

  /// [fire], answering the run as it was left: running with its session, or
  /// failed with the reason. A webhook answers its caller from it.
  Future<AutomationRun> start(
    Automation automation,
    DateTime scheduledFor, {
    String note = '',
    AutomationRun? queued,
    AutomationRunCause? startedBy,
    Map<String, String> variables = const {},
  }) async {
    final now = _now();
    final values = queued?.variables ?? variables;
    // Someone else's words reach the agent quoted as data, never as its own.
    if (values.isNotEmpty) {
      automation = automation.copyWith(
        prompt: fillAgentText(automation.prompt, values),
      );
    }
    final branch = automation.github?.kind.isPullRequest ?? false
        ? values['github.pr.branch']
        : null;
    // The row exists before anything can fail; a drained queue entry *is*
    // this run, updated in place.
    var run = queued == null
        ? AutomationRun(
            id: _newId(),
            automationId: automation.id,
            scheduledFor: scheduledFor,
            firedAt: now,
            state: AutomationRunState.running,
            reason: note,
            // A filled prompt is this run's own; keep what was sent.
            prompt: automation.isWebhook || values.isNotEmpty
                ? automation.prompt
                : null,
            startedBy: startedBy,
            variables: values,
          )
        : queued.copyWith(
            state: AutomationRunState.running,
            reason: note.isEmpty ? queued.reason : note,
          );
    if (queued == null) {
      _dao.insertRun(run);
    } else {
      _dao.updateRun(run);
    }

    void settle(AutomationRunState state, String reason) {
      run = run.copyWith(state: state, reason: reason, finishedAt: now);
      _dao.updateRun(run);
      _onChanged();
    }

    final refusal = _preflight.refusalFor(automation);
    if (refusal != null) {
      settle(AutomationRunState.failed, refusal.reason);
      return run;
    }

    final repository = _facts.repository(automation.repositoryId);
    final installation = _facts.installation(automation.agentInstallationId);
    // The gate already refused both; this is the compiler's copy of that fact.
    if (repository == null || installation == null) {
      settle(
        AutomationRunState.failed,
        'The checkout or the agent went away just before the run started.',
      );
      return run;
    }

    String? baseId;
    try {
      baseId = await _checkpoints.capture(
        repository.path,
        runId: run.id,
        label: 'before automation "${automation.name}"',
      );
    } on Object catch (error) {
      settle(
        AutomationRunState.failed,
        'The working tree could not be recorded before this run, so there '
        'would be nothing to undo it with: $error',
      );
      return run;
    }
    run = run.copyWith(baseCheckpointId: baseId);
    _dao.updateRun(run);

    try {
      final sessionId = await _launcher.launch(
        automation,
        repository,
        installation,
        branch: branch == null || branch.isEmpty ? null : branch,
      );
      run = run.copyWith(sessionId: sessionId);
      _dao.updateRun(run);
      _onChanged();
    } on Object catch (error) {
      settle(
        AutomationRunState.failed,
        'The session could not be started: $error',
      );
    }
    return run;
  }
}
