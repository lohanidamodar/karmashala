import 'dart:async';

import '../domain/automation.dart';
import '../domain/automation_command.dart';
import '../domain/automation_run.dart';
import '../domain/automation_steps.dart';
import '../domain/github_trigger.dart';
import 'automation_records.dart';
import 'automation_firing.dart';
import 'automation_session_launcher.dart';
import 'automation_step_io.dart';
import 'checkout_facts.dart';
import 'run_base_checkpoint.dart';
import 'unattended_preflight.dart';

/// Settles a run the way a session ending does: its verdict, its checks,
/// its failure budget, then the queue.
typedef AutomationRunFinish =
    void Function(AutomationRun run, AutomationRunState state, String reason);

/// Firing an automation: the gate again, a checkpoint of the base, a session
/// or a command. A refusal is a recorded `failed` run — a silent skip would
/// repeat forever.
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
    this._commands,
    this._finish,
  }) : _dao = automations,
       _onChanged = onChanged ?? _nothing;

  final StepCommandRunner? _commands;

  /// Set once the settler exists, which is built after this runner.
  AutomationRunFinish? _finish;
  set finish(AutomationRunFinish finish) => _finish = finish;

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
    final pullRequest = PullRequestCheckout.of(automation.github, values);
    final pushNote = pullRequest?.pushNote;
    if (pushNote != null) {
      // The agent is told too, or it spends the run on a push that goes
      // nowhere.
      automation = automation.copyWith(
        prompt: '${automation.prompt}\n\n$pushNote',
      );
    }
    String said(String reason) =>
        pushNote == null ? reason : [reason, pushNote].join(' ').trim();
    // The row exists before anything can fail; a drained queue entry *is*
    // this run, updated in place.
    var run = queued == null
        ? AutomationRun(
            id: _newId(),
            automationId: automation.id,
            scheduledFor: scheduledFor,
            firedAt: now,
            state: AutomationRunState.running,
            reason: said(note),
            // A filled prompt is this run's own; keep what was sent.
            prompt: automation.isWebhook || values.isNotEmpty
                ? automation.prompt
                : null,
            startedBy: startedBy,
            variables: values,
          )
        : queued.copyWith(
            state: AutomationRunState.running,
            reason: said(note.isEmpty ? queued.reason : note),
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

    if (automation.runsCommand) {
      return _startCommand(automation, run, values, settle);
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
        pullRequest: pullRequest,
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

  /// A command first step: a checkpoint when it runs in a checkout, then the
  /// command, settled when it exits. Answers the run as it was left running.
  Future<AutomationRun> _startCommand(
    Automation automation,
    AutomationRun run,
    Map<String, String> values,
    void Function(AutomationRunState state, String reason) settle,
  ) async {
    final commands = _commands;
    final finish = _finish;
    if (commands == null || finish == null) {
      settle(
        AutomationRunState.failed,
        'This server runs no commands for automations.',
      );
      return run;
    }
    if (automation.command!.refusal case final why?) {
      settle(AutomationRunState.failed, why);
      return run;
    }
    final repository = automation.folder == null
        ? _facts.repository(automation.repositoryId)
        : null;
    if (automation.folder == null && repository == null) {
      settle(
        AutomationRunState.failed,
        'The checkout went away just before the run started.',
      );
      return run;
    }
    if (repository != null) {
      try {
        final baseId = await _checkpoints.capture(
          repository.path,
          runId: run.id,
          label: 'before automation "${automation.name}"',
        );
        run = run.copyWith(baseCheckpointId: baseId);
        _dao.updateRun(run);
      } on Object catch (error) {
        settle(
          AutomationRunState.failed,
          'The working tree could not be recorded before this run, so there '
          'would be nothing to undo it with: $error',
        );
        return run;
      }
    }
    _onChanged();
    final timeout = automation.maxRuntime ?? kCommandTimeLimit;
    final started = run;
    unawaited(() async {
      StepCommandResult result;
      try {
        result = await commands.run(
          automation,
          started,
          command: automation.command!.text,
          environment: stepEnvironment({
            ...values,
            'automation': automation.name,
            'project': repository?.name ?? automation.folder!.path,
          }),
          timeout: timeout,
        );
      } on StateError catch (error) {
        finish(
          started,
          AutomationRunState.failed,
          'The command did not start: ${error.message}',
        );
        return;
      }
      // Settled meanwhile, by a person or a shutdown: theirs stands.
      final now = _dao.runById(started.id);
      if (now == null || now.state != AutomationRunState.running) return;
      final ended = now.copyWith(
        exitCode: result.exitCode,
        output: capStepOutput(result.output),
      );
      if (result.timedOut) {
        finish(
          ended,
          AutomationRunState.failed,
          'Stopped after ${describeGap(timeout)}, its time limit.',
        );
      } else if (result.exitCode == 0) {
        finish(ended, AutomationRunState.finished, 'It exited with 0.');
      } else {
        finish(
          ended,
          AutomationRunState.failed,
          'It exited with ${result.exitCode}.',
        );
      }
    }());
    return run;
  }
}
