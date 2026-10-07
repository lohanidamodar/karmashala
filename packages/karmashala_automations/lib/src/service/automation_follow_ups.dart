import 'package:karmashala_core/verdicts.dart';

import '../domain/automation.dart';
import '../domain/automation_run.dart';
import '../domain/automation_steps.dart';
import '../domain/scheduled_resume.dart';
import 'automation_records.dart';

/// The tell and notify steps, once a run has settled and its checks (if it
/// has a check step) have been recorded. Each step's outcome is kept on the
/// run, so a step that did nothing says why.
class AutomationFollowUps {
  AutomationFollowUps({
    required AutomationRecords automations,
    required this._resumes,
    required this._repositoryName,
    required this._notify,
    required this._now,
    required this._newId,
    void Function()? onChanged,
  }) : _dao = automations,
       _onChanged = onChanged ?? _nothing;

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

  static void _nothing() {}

  /// Whether [run] failed: its agent did not finish, or a check did not pass.
  bool failedOf(Automation automation, AutomationRun run) {
    if (run.state != AutomationRunState.finished) return true;
    if (!automation.steps.checks) return false;
    return _dao
        .checksFor(run.id)
        .any((check) => check.verdict != VerificationVerdict.pass);
  }

  /// What `{{…}}` stands for in [run]'s step texts.
  Map<String, String> valuesFor(Automation automation, AutomationRun run) {
    final failed = failedOf(automation, run);
    final checks = _dao.checksFor(run.id);
    return {
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

  /// Runs [settled]'s tell and notify steps, as its automation now says.
  void after(AutomationRun settled) {
    final run = _dao.runById(settled.id) ?? settled;
    final automation = _dao.getById(run.automationId);
    if (automation == null) return;
    final failed = failedOf(automation, run);
    final values = valuesFor(automation, run);
    final results = <AutomationStepResult>[];
    for (final kind in const [
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
      final text = fillStepText(step.text.trim(), values);
      try {
        final detail = kind == AutomationStepKind.tell
            ? _tell(automation, run, text)
            : _sendNotification(automation, run, text, failed: failed);
        results.add(_result(kind, AutomationStepOutcome.done, detail));
      } on StateError catch (error) {
        results.add(_result(kind, AutomationStepOutcome.failed, error.message));
      }
    }
    if (results.isEmpty) return;
    _dao.updateRun(run.copyWith(stepResults: results));
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
        message: text,
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
