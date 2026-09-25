import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_verification/command_checks.dart';
import 'package:karmashala_verification/verification.dart';

import '../domain/automation_check_verdict.dart';
import '../domain/automation_run.dart';
import '../domain/project_check.dart';
import '../store/automation_dao.dart';
import '../store/project_check_dao.dart';
import 'check_command_runner.dart';
import 'checkout_facts.dart';

/// One session's checks: each as it ran, and the one run that records them.
typedef SessionChecks = ({List<CommandCheck> checks, VerificationRun run});

/// Runs a checkout's project checks one after another and records what each
/// said, as Karmashala's own reading ([kAppVerifierId]) — never the session's
/// claim about itself. A check that could not run is inconclusive, never a pass.
class ProjectCheckRunner {
  ProjectCheckRunner({
    required AutomationDao automations,
    required this._checks,
    required this._facts,
    required this._commands,
    required this._recorder,
    required this._now,
    void Function()? onChanged,
    void Function(String message)? log,
  }) : _dao = automations,
       _onChanged = onChanged ?? _nothing,
       _log = log ?? _ignore;

  final AutomationDao _dao;
  final ProjectCheckDao _checks;
  final CheckoutFacts _facts;
  final CheckCommandRunner _commands;
  final CommandCheckRecorder _recorder;
  final DateTime Function() _now;
  final void Function() _onChanged;
  final void Function(String message) _log;

  static void _nothing() {}
  static void _ignore(String _) {}

  Future<void> _pending = Future<void>.value();

  /// The last batch a settled run set off has been written.
  Future<void> drain() => _pending;

  /// Runs [run]'s checkout's checks and records a verdict for each. Started and
  /// not awaited: a test suite takes minutes and nobody is holding on.
  void start(AutomationRun run) {
    // Not chained: a sequence that never finishes must not hold up the next.
    _pending = recordRun(run).catchError((Object error) {
      _log('recording a project check verdict failed: $error');
    });
  }

  /// [start], awaited.
  Future<void> recordRun(AutomationRun run) async {
    final automation = _dao.getById(run.automationId);
    if (automation == null) return;
    final checks = _checks.forRepository(automation.repositoryId);
    if (checks.isEmpty) {
      // Observed, with nothing to observe with: not the same as never looked.
      _dao.noteChecksObserved(run.id, _now());
      _onChanged();
      return;
    }
    final directory = _facts.repository(automation.repositoryId)?.path;
    var ordinal = 0;
    for (final check in checks) {
      ordinal++;
      final verdict = await _runOne(
        run: run,
        check: check,
        ordinal: ordinal,
        directory: directory,
      );
      _dao.insertRunCheck(verdict);
      _onChanged();
    }
    _dao.noteChecksObserved(run.id, _now());
    _onChanged();
  }

  /// Records every check of [run]'s checkout as not run, for [reason] — a
  /// check nobody could run is inconclusive, never skipped in silence.
  void recordNotRun(AutomationRun run, String reason) {
    final automation = _dao.getById(run.automationId);
    if (automation == null) return;
    var ordinal = 0;
    for (final check in _checks.forRepository(automation.repositoryId)) {
      ordinal++;
      _dao.insertRunCheck(
        AutomationCheckVerdict(
          runId: run.id,
          ordinal: ordinal,
          checkId: check.id,
          name: check.name,
          command: check.command,
          verdict: VerificationVerdict.inconclusive,
          reason: '"${check.name}" did not run: $reason',
          checkedAt: _now(),
        ),
      );
    }
    _dao.noteChecksObserved(run.id, _now());
    _onChanged();
  }

  Future<AutomationCheckVerdict> _runOne({
    required AutomationRun run,
    required ProjectCheck check,
    required int ordinal,
    required EnvironmentPath? directory,
  }) async {
    final startedAt = _now();
    final result = await _execute(
      check,
      directory,
      title: '${check.name} · ${run.id}',
    );
    VerificationVerdict verdict;
    String reason;
    String? verificationRunId;
    final refusal = result.refusal;
    if (refusal != null) {
      verdict = VerificationVerdict.inconclusive;
      reason = refusal;
    } else {
      final recorded = await _recorder.recordOne(
        title: '${check.name} · ${directory!.path}',
        command: check.command,
        workingDirectory: directory.path,
        environmentId: directory.environmentId,
        startedAt: startedAt,
        exitCode: result.exitCode,
        output: result.tail.join('\n'),
        sessionId: run.sessionId,
        producedBySessionId: kAppVerifierId,
      );
      verdict = recorded.verdict ?? VerificationVerdict.inconclusive;
      reason = recorded.reason ?? '';
      verificationRunId = recorded.id;
    }
    return AutomationCheckVerdict(
      runId: run.id,
      ordinal: ordinal,
      checkId: check.id,
      name: check.name,
      command: check.command,
      verdict: verdict,
      reason: reason,
      verificationRunId: verificationRunId,
      checkedAt: _now(),
    );
  }

  /// Runs [session]'s checkout's checks in [directory] — where its agent
  /// works — and records them as **one** verification run against it, the
  /// worst verdict of the batch. Null when the checkout has none.
  Future<SessionChecks?> runForSession(
    Session session,
    EnvironmentPath? directory,
  ) async {
    final checks = _checks.forRepository(session.repositoryId);
    if (checks.isEmpty) return null;
    final startedAt = _now();
    final ran = <CommandCheck>[];
    for (final check in checks) {
      final result = await _execute(
        check,
        directory,
        title: '${check.name} · ${session.title}',
      );
      ran.add(
        CommandCheck(
          name: check.name,
          command: check.command,
          exitCode: result.exitCode,
          output: result.tail.join('\n'),
          refusal: result.refusal,
        ),
      );
    }
    final run = await _recorder.recordBatch(
      title: 'Project checks · ${session.title}',
      startedAt: startedAt,
      checks: ran,
      sessionId: session.id,
      producedBySessionId: kAppVerifierId,
    );
    return (checks: ran, run: run);
  }

  Future<CheckExecution> _execute(
    ProjectCheck check,
    EnvironmentPath? directory, {
    required String title,
  }) async {
    final commandRefusal = projectCheckCommandRefusal(check.command);
    if (commandRefusal != null) {
      return CheckExecution.refused(
        '"${check.name}" did not run: $commandRefusal',
      );
    }
    if (directory == null) {
      return CheckExecution.refused(
        '"${check.name}" did not run: no checkout says where it would run. '
        'Whether the work still stands is unknown, not proven.',
      );
    }
    try {
      return await _commands.execute(check, directory: directory, title: title);
    } on Object catch (error) {
      return CheckExecution.refused(
        '"${check.name}" could not be started: $error',
      );
    }
  }
}
