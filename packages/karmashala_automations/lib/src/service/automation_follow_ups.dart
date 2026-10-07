import 'package:karmashala_core/verdicts.dart';

import '../domain/automation.dart';
import '../domain/automation_attribution.dart';
import '../domain/automation_run.dart';
import '../domain/automation_steps.dart';
import '../domain/github_trigger.dart';
import '../domain/scheduled_resume.dart';
import 'automation_records.dart';
import 'automation_step_io.dart';

/// The steps after the agent, once a run has settled and its checks (if it
/// has a check step) have been recorded: command, webhook, tell, notify.
/// Each step's outcome is kept on the run, so a step that did nothing says
/// why, and what a command or webhook returned is a variable for the next.
class AutomationFollowUps {
  AutomationFollowUps({
    required AutomationRecords automations,
    required this._resumes,
    required this._repositoryName,
    required this._notify,
    required this._now,
    required this._newId,
    void Function()? onChanged,
    this._commands,
    this._webhooks,
    bool Function(String repositoryId)? checksOn,
  }) : _dao = automations,
       _onChanged = onChanged ?? _nothing,
       _checksOn = checksOn ?? _never;

  final AutomationRecords _dao;
  final ResumeRecords _resumes;
  final String Function(String repositoryId) _repositoryName;

  /// Files [text] where a person sees it. Throws with the reason it could not.
  final void Function(
    Automation automation,
    AutomationRun run,
    String text, {
    required bool failed,
  })
  _notify;
  final DateTime Function() _now;
  final String Function() _newId;
  final void Function() _onChanged;
  final StepCommandRunner? _commands;
  final StepWebhookPoster? _webhooks;

  /// Whether the checkout has checks on and at least one check — what a
  /// command step needs before it runs unattended.
  final bool Function(String repositoryId) _checksOn;

  static void _nothing() {}
  static bool _never(String _) => false;

  /// Whether [run] failed: its agent did not finish, or a check did not pass.
  bool failedOf(Automation automation, AutomationRun run) {
    if (run.state != AutomationRunState.finished) return true;
    if (!automation.steps.checks) return false;
    return _dao
        .checksFor(run.id)
        .any((check) => check.verdict != VerificationVerdict.pass);
  }

  /// What `{{…}}` stands for in [run]'s step texts, before any step ran.
  Map<String, String> valuesFor(Automation automation, AutomationRun run) {
    final failed = failedOf(automation, run);
    final checks = _dao.checksFor(run.id);
    return {
      ...run.variables,
      'automation': automation.name,
      'project': _repositoryName(automation.repositoryId),
      'run.status': failed ? 'failed' : 'succeeded',
      'steps.agent.output': run.reason,
      'steps.check.output': checks.isEmpty
          ? 'No check ran.'
          : [
              for (final check in checks)
                '${check.name}: ${check.verdict.label}. ${check.reason}'.trim(),
            ].join('\n'),
    };
  }

  /// Runs [settled]'s steps after the checks, as its automation now says.
  Future<void> after(AutomationRun settled) async {
    final run = _dao.runById(settled.id) ?? settled;
    final automation = _dao.getById(run.automationId);
    if (automation == null) return;
    var failed = failedOf(automation, run);
    final values = valuesFor(automation, run);
    final results = <AutomationStepResult>[];
    for (final kind in const [
      AutomationStepKind.command,
      AutomationStepKind.webhook,
      AutomationStepKind.tell,
      AutomationStepKind.notify,
    ]) {
      final step = automation.steps.of(kind);
      if (step == null) continue;
      if (!step.when.matches(failed: failed)) {
        results.add(
          _result(
            kind,
            AutomationStepOutcome.skipped,
            failed
                ? 'Not run: it is set to run only if it succeeded.'
                : 'Not run: it is set to run only if something failed.',
          ),
        );
        continue;
      }
      try {
        final detail = switch (kind) {
          AutomationStepKind.command => await _command(
            automation,
            run,
            step,
            values,
          ),
          AutomationStepKind.webhook => await _webhook(run, step, values),
          AutomationStepKind.tell => _tell(
            automation,
            run,
            fillAgentText(step.text.trim(), values),
          ),
          _ => _sendNotification(
            automation,
            run,
            fillStepText(step.text.trim(), values),
            failed: failed,
          ),
        };
        results.add(_result(kind, AutomationStepOutcome.done, detail));
      } on StateError catch (error) {
        results.add(_result(kind, AutomationStepOutcome.failed, error.message));
        if (kind == AutomationStepKind.command ||
            kind == AutomationStepKind.webhook) {
          failed = true;
          values['run.status'] = 'failed';
        }
      }
    }
    if (results.isEmpty) return;
    _dao.updateRun(
      (_dao.runById(run.id) ?? run).copyWith(stepResults: results),
    );
    _onChanged();
  }

  AutomationStepResult _result(
    AutomationStepKind kind,
    AutomationStepOutcome outcome,
    String detail,
  ) => AutomationStepResult(
    kind: kind,
    outcome: outcome,
    detail: detail,
    at: _now(),
  );

  /// The command, with every value as an environment variable and none in
  /// its text. Only where checks are on, as every unattended change is.
  Future<String> _command(
    Automation automation,
    AutomationRun run,
    AutomationStep step,
    Map<String, String> values,
  ) async {
    final commands = _commands;
    if (commands == null) {
      throw StateError('This server runs no commands for automations.');
    }
    if (step.refusal case final why?) throw StateError(why);
    if (!_checksOn(automation.repositoryId)) {
      throw StateError(
        'Not run: checks are off for this checkout, or it has none. A command '
        'runs with nobody watching only where checks are on.',
      );
    }
    final result = await commands.run(
      automation,
      run,
      command: step.text,
      environment: stepEnvironment(values),
      timeout: step.timeout,
    );
    final output = capStepOutput(result.output);
    values['steps.command.output'] = output;
    values['steps.command.exit_code'] = '${result.exitCode ?? ''}';
    if (result.timedOut) {
      throw StateError(
        'Stopped after ${describeGap(step.timeout)}, its time limit.',
      );
    }
    if (result.exitCode != 0) {
      throw StateError('It exited with ${result.exitCode}.');
    }
    return 'It exited with 0.';
  }

  Future<String> _webhook(
    AutomationRun run,
    AutomationStep step,
    Map<String, String> values,
  ) async {
    final webhooks = _webhooks;
    if (webhooks == null) {
      throw StateError('This server calls no webhooks for automations.');
    }
    if (step.refusal case final why?) throw StateError(why);
    final String body;
    try {
      body = fillJsonBody(step.text, values);
    } on FormatException {
      throw StateError('The body was not JSON once its values were put in.');
    }
    final url = Uri.parse(step.url.trim());
    final answer = await webhooks.post(
      url,
      body: body,
      idempotencyKey: '${run.id}-webhook',
      allowPrivate: step.allowPrivate,
      timeout: step.timeout,
    );
    values['steps.webhook.status'] = '${answer.status}';
    values['steps.webhook.output'] = capStepOutput(answer.body);
    if (answer.status < 200 || answer.status >= 300) {
      throw StateError('${url.host} answered ${answer.status}.');
    }
    return '${url.host} answered ${answer.status}.';
  }

  /// A scheduled resume due now: the one path that already sends a session a
  /// message with nobody there — gated, and resuming an ended session.
  String _tell(Automation automation, AutomationRun run, String text) {
    final sessionId = run.sessionId;
    if (sessionId == null) {
      throw StateError('This run started no session to tell.');
    }
    if (text.isEmpty) throw StateError('The message is empty.');
    if (_resumes.liveFor(sessionId) != null) {
      throw StateError(
        'A resume is already waiting for that session, so nothing was sent.',
      );
    }
    final now = _now();
    _resumes.replaceFor(
      ScheduledResume(
        id: _newId(),
        sessionId: sessionId,
        fireAt: now,
        state: ScheduledResumeState.pending,
        scheduledAt: now,
        message: AutomationAttribution(
          automationId: automation.id,
          name: automation.name,
        ).render(text),
        latePolicy: ResumeLatePolicy.resume,
        scheduledBy: 'automation "${automation.name}"',
      ),
      now: now,
    );
    return 'Sent to the session: "$text"';
  }

  String _sendNotification(
    Automation automation,
    AutomationRun run,
    String text, {
    required bool failed,
  }) {
    final message = text.isEmpty
        ? '${automation.name}: ${failed ? 'failed' : 'succeeded'}'
        : text;
    _notify(automation, run, message, failed: failed);
    return 'Notified: "$message"';
  }
}
