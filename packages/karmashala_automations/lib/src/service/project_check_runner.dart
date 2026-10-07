import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_verification/check_results.dart';
import 'package:karmashala_verification/command_checks.dart';
import 'package:karmashala_verification/verification.dart';

import '../domain/automation_check_verdict.dart';
import '../domain/automation_run.dart';
import '../domain/project_check.dart';
import 'automation_records.dart';

import 'check_command_runner.dart';
import 'checkout_facts.dart';

/// One session's checks: each as it ran, and the one run that records them.
typedef SessionChecks = ({List<CommandCheck> checks, VerificationRun run});

/// Runs a checkout's project checks one after another and records what each
/// said, as Karmashala's own reading ([kAppVerifierId]) — never the session's
/// claim about itself. A check that could not run is inconclusive, never a pass.
class ProjectCheckRunner {
  ProjectCheckRunner({
    required AutomationRecords automations,
    required this._checks,
    required this._facts,
    required this._commands,
    required this._recorder,
    required this._now,
    this._results,
    void Function()? onChanged,
    void Function(String message)? log,
  }) : _dao = automations,
       _onChanged = onChanged ?? _nothing,
       _log = log ?? _ignore;

  final AutomationRecords _dao;
  final ProjectCheckRecords _checks;
  final CheckoutFacts _facts;
  final CheckCommandRunner _commands;
  final CommandCheckRecorder _recorder;
  final DateTime Function() _now;

  /// Where parsed results are kept and their baselines read; null keeps none.
  final CheckResultRecords? _results;
  final void Function() _onChanged;
  final void Function(String message) _log;

  static void _nothing() {}
  static void _ignore(String _) {}

  Future<void> _pending = Future<void>.value();

  /// The last batch a settled run set off has been written.
  Future<void> drain() => _pending;

  /// Runs [run]'s checkout's checks and records a verdict for each. Started and
  /// not awaited: a test suite takes minutes and nobody is holding on.
  /// [directory] is where the run's agent worked, when not the checkout
  /// itself; [then] follows once every verdict is written.
  void start(
    AutomationRun run, {
    EnvironmentPath? directory,
    void Function()? then,
  }) {
    // Not chained: a sequence that never finishes must not hold up the next.
    _pending = recordRun(run, directory: directory)
        .catchError((Object error) {
          _log('recording a project check verdict failed: $error');
        })
        .whenComplete(() => then?.call());
  }

  /// [start], awaited.
  Future<void> recordRun(
    AutomationRun run, {
    EnvironmentPath? directory,
  }) async {
    final automation = _dao.getById(run.automationId);
    if (automation == null) return;
    final checks = _checks.forRepository(automation.repositoryId);
    if (checks.isEmpty) {
      // Observed, with nothing to observe with: not the same as never looked.
      _dao.noteChecksObserved(run.id, _now());
      _onChanged();
      return;
    }
    directory ??= _facts.repository(automation.repositoryId)?.path;
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
      final automation = _dao.getById(run.automationId);
      final results = _parse(result, directory);
      final change = automation == null || results == null
          ? null
          : _change(
              repositoryId: automation.repositoryId,
              checkName: check.name,
              results: results,
              startedAt: run.firedAt,
              sessionId: run.sessionId,
              directory: directory?.path,
            );
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
        results: results,
        change: change,
      );
      if (automation != null && results != null) {
        _keep(
          recorded.id,
          sessionId: run.sessionId,
          repositoryId: automation.repositoryId,
          directory: directory,
          checkName: check.name,
          results: results,
        );
      }
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
      final results = _parse(result, directory);
      ran.add(
        CommandCheck(
          name: check.name,
          command: check.command,
          exitCode: result.exitCode,
          output: result.tail.join('\n'),
          refusal: result.refusal,
          results: results,
          change: results == null
              ? null
              : _change(
                  repositoryId: session.repositoryId,
                  checkName: check.name,
                  results: results,
                  startedAt: session.createdAt,
                  sessionId: session.id,
                  directory: directory?.path,
                ),
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
    for (final check in ran) {
      if (check.results case final results?) {
        _keep(
          run.id,
          sessionId: session.id,
          repositoryId: session.repositoryId,
          directory: directory,
          checkName: check.name,
          results: results,
        );
      }
    }
    return (checks: ran, run: run);
  }

  /// The newest structured reading of each of [session]'s checks, with what it
  /// changed against the baseline [changeAgainstBaseline] picks.
  List<({RecordedCheckResults latest, CheckResultsChange? change})>
  latestResults(Session session) {
    final records = _results;
    if (records == null) return const [];
    final newest = <String, RecordedCheckResults>{};
    for (final reading in records.forSession(session.id)) {
      newest[reading.checkName] = reading;
    }
    return [
      for (final reading in newest.values)
        (
          latest: reading,
          change: _change(
            repositoryId: session.repositoryId,
            checkName: reading.checkName,
            results: reading.results,
            startedAt: session.createdAt,
            sessionId: session.id,
            directory: reading.directory,
            excludingId: reading.id,
          ),
        ),
    ];
  }

  CheckResults? _parse(CheckExecution result, EnvironmentPath? directory) =>
      result.refusal != null
      ? null
      : parseCheckOutput(
          result.transcript ?? result.tail.join('\n'),
          root: directory?.path,
          columns: result.columns,
          truncated: result.transcriptTruncated,
        );

  CheckResultsChange? _change({
    required String repositoryId,
    required String checkName,
    required CheckResults results,
    required DateTime startedAt,
    required String? sessionId,
    required String? directory,
    int? excludingId,
  }) {
    final records = _results;
    if (records == null) return null;
    return changeAgainstBaseline(
      _Excluding(records, excludingId),
      repositoryId: repositoryId,
      checkName: checkName,
      current: results,
      sessionStartedAt: startedAt,
      directory: directory,
      sessionId: sessionId,
    );
  }

  void _keep(
    String verificationRunId, {
    required String? sessionId,
    required String repositoryId,
    required EnvironmentPath? directory,
    required String checkName,
    required CheckResults results,
  }) {
    final records = _results;
    if (records == null) return;
    try {
      records.record(
        RecordedCheckResults(
          verificationRunId: verificationRunId,
          sessionId: sessionId,
          repositoryId: repositoryId,
          directory: directory?.path,
          checkName: checkName,
          recordedAt: _now(),
          results: results,
        ),
      );
    } on Object catch (error) {
      // The verdict is already recorded; losing its structure loses no verdict.
      _log('recording structured check results failed: $error');
    }
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

/// [_records] without reading [_id], so a reading is never its own baseline.
class _Excluding implements CheckResultRecords {
  const _Excluding(this._records, this._id);

  final CheckResultRecords _records;
  final int? _id;

  @override
  void record(RecordedCheckResults results) => _records.record(results);

  @override
  List<RecordedCheckResults> forSession(String sessionId) => [
    for (final reading in _records.forSession(sessionId))
      if (_id == null || reading.id != _id) reading,
  ];

  @override
  RecordedCheckResults? latestBefore({
    required String repositoryId,
    required String checkName,
    required DateTime before,
    String? directory,
    String? excludingSessionId,
  }) => _records.latestBefore(
    repositoryId: repositoryId,
    checkName: checkName,
    before: before,
    directory: directory,
    excludingSessionId: excludingSessionId,
  );
}
