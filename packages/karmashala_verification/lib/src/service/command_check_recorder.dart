import 'dart:convert';

import '../domain/check_results.dart';
import '../domain/check_results_change.dart';
import '../domain/command_check.dart';
import '../domain/verification_artifact.dart';
import '../domain/verification_run.dart';
import '../domain/verification_step.dart';
import '../domain/verification_target.dart';
import '../store/verification_artifact_store.dart';
import 'verification_records.dart';

/// Writes the gates Karmashala ran itself as verification runs. Takes no
/// recording slot, so it can never clobber a run an agent has open. The files
/// are written first; the run, its steps and artifacts go in one record.
class CommandCheckRecorder {
  CommandCheckRecorder(
    this._records,
    this._store, {
    required this._newId,
    required this._now,
    void Function()? onChanged,
  }) : _onChanged = onChanged ?? _nothing;

  final VerificationRecords _records;
  final VerificationArtifactStore _store;
  final String Function() _newId;
  final DateTime Function() _now;
  final void Function() _onChanged;

  static void _nothing() {}

  /// Records several gates as **one** run: a step and an output per check, and
  /// the worst verdict among them ([worstVerdict]).
  Future<VerificationRun> recordBatch({
    required String title,
    required DateTime startedAt,
    required List<CommandCheck> checks,
    String? sessionId,
    String? producedBySessionId,
  }) async {
    final id = _newId();
    final directory = await _store.createDirectory(id);
    final finishedAt = _now();
    final verdicts = [for (final check in checks) check.verdict];
    final steps = <VerificationStep>[
      for (final (i, check) in checks.indexed)
        VerificationStep(
          ordinal: i + 1,
          kind: VerificationStepKind.other,
          summary: '${check.name}: ${check.command.join(' ')}',
          detail: _withResults(
            check.refusal ??
                switch (check.exitCode) {
                  0 => 'passed',
                  null => 'stopped without an exit code Karmashala observed',
                  final code => 'exited $code',
                },
            check.resultsLine,
          ),
          at: finishedAt,
          ok: verdicts[i] == VerificationVerdict.pass,
        ),
    ];
    final failed = [
      for (final (i, check) in checks.indexed)
        if (verdicts[i] != VerificationVerdict.pass) check.name,
    ];
    final passed = checks.length - failed.length;
    final run = VerificationRun(
      id: id,
      title: title,
      target: const VerificationTarget.change(),
      sessionId: sessionId,
      producedBySessionId: producedBySessionId,
      startedAt: startedAt,
      finishedAt: finishedAt,
      verdict: worstVerdict(verdicts),
      reason: failed.isEmpty
          ? '${checks.length == 1 ? 'The check' : 'All ${checks.length} checks'} passed.'
          : '$passed of ${checks.length} passed; not passed: '
                '${failed.join(', ')}.',
      artifactDirectory: directory.path,
      steps: steps,
    );
    final artifacts = [
      for (final (i, check) in checks.indexed)
        if (check.output.trim().isNotEmpty)
          await _store.writeText(
            runId: id,
            name: 'output-${i + 1}',
            kind: VerificationArtifactKind.other,
            label: check.name,
            text: check.output,
            stepOrdinal: i + 1,
            at: finishedAt,
          ),
      for (final (i, check) in checks.indexed)
        if (check.results case final results?)
          await _writeResults(
            runId: id,
            name: 'results-${i + 1}',
            label: '${check.name} — results',
            results: results,
            change: check.change,
            stepOrdinal: i + 1,
            at: finishedAt,
          ),
    ];
    final stored = await _records.record(run.copyWith(artifacts: artifacts));
    _onChanged();
    return stored;
  }

  /// Records one gate. An exit code nobody saw is `inconclusive`, never a pass.
  Future<VerificationRun> recordOne({
    required String title,
    required List<String> command,
    required String workingDirectory,
    required String environmentId,
    required DateTime startedAt,
    required int? exitCode,
    String output = '',
    String? sessionId,
    String? producedBySessionId,
    CheckResults? results,
    CheckResultsChange? change,
  }) async {
    final id = _newId();
    final directory = await _store.createDirectory(id);
    final finishedAt = _now();
    final verdict = switch (exitCode) {
      0 => VerificationVerdict.pass,
      null => VerificationVerdict.inconclusive,
      _ => VerificationVerdict.fail,
    };
    final line = command.join(' ');
    final step = VerificationStep(
      ordinal: 1,
      kind: VerificationStepKind.other,
      summary: line,
      detail: _withResults(
        'in $workingDirectory ($environmentId)',
        CommandCheck(
          name: line,
          command: command,
          results: results,
          change: change,
        ).resultsLine,
      ),
      at: finishedAt,
      ok: exitCode == 0,
    );
    final run = VerificationRun(
      id: id,
      title: title,
      target: const VerificationTarget.change(),
      sessionId: sessionId,
      producedBySessionId: producedBySessionId,
      startedAt: startedAt,
      finishedAt: finishedAt,
      verdict: verdict,
      reason: switch (exitCode) {
        0 => '$line passed.',
        null =>
          '$line stopped without an exit code Karmashala observed, so whether '
              'it passed is unknown.',
        final code => '$line exited $code.',
      },
      artifactDirectory: directory.path,
      steps: <VerificationStep>[step],
    );
    final artifacts = [
      if (output.trim().isNotEmpty)
        await _store.writeText(
          runId: id,
          name: 'output',
          kind: VerificationArtifactKind.other,
          label: line,
          text: output,
          stepOrdinal: 1,
          at: finishedAt,
        ),
      if (results != null)
        await _writeResults(
          runId: id,
          name: 'results',
          label: '$line — results',
          results: results,
          change: change,
          stepOrdinal: 1,
          at: finishedAt,
        ),
    ];
    final stored = await _records.record(run.copyWith(artifacts: artifacts));
    _onChanged();
    return stored;
  }

  /// The structured reading, beside the raw output rather than instead of it.
  Future<VerificationArtifact> _writeResults({
    required String runId,
    required String name,
    required String label,
    required CheckResults results,
    required CheckResultsChange? change,
    required int stepOrdinal,
    required DateTime at,
  }) => _store.writeText(
    runId: runId,
    name: name,
    kind: VerificationArtifactKind.other,
    label: label,
    text: const JsonEncoder.withIndent('  ').convert({
      'summary': results.summary,
      ...results.toJson(),
      if (change != null) 'change': change.toJson(),
    }),
    stepOrdinal: stepOrdinal,
    at: at,
  );
}

String _withResults(String detail, String? results) =>
    results == null ? detail : '$detail · $results';

/// Sortable, unique, and legible in a folder listing: the id a verification
/// run's directory is named by.
String verificationRunId(DateTime now) {
  final at = now.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return 'run-${at.year}${two(at.month)}${two(at.day)}'
      '-${two(at.hour)}${two(at.minute)}${two(at.second)}'
      '-${at.millisecond.toString().padLeft(3, '0')}';
}
