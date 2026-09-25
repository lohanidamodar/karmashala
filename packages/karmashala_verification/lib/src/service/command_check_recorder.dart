import '../domain/command_check.dart';
import '../domain/verification_artifact.dart';
import '../domain/verification_run.dart';
import '../domain/verification_step.dart';
import '../domain/verification_target.dart';
import '../store/verification_artifact_store.dart';
import '../store/verification_dao.dart';

/// Writes the gates Karmashala ran itself as verification runs. Takes no
/// recording slot, so it can never clobber a run an agent has open — which is
/// what lets the app and the session host both use it on one store.
class CommandCheckRecorder {
  CommandCheckRecorder(
    this._dao,
    this._store, {
    required this._newId,
    required this._now,
    void Function()? onChanged,
  }) : _onChanged = onChanged ?? _nothing;

  final VerificationDao _dao;
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
          detail:
              check.refusal ??
              switch (check.exitCode) {
                0 => 'passed',
                null => 'stopped without an exit code Karmashala observed',
                final code => 'exited $code',
              },
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
    _dao.insertRun(run);
    for (final step in steps) {
      _dao.insertStep(id, step);
    }
    for (final (i, check) in checks.indexed) {
      if (check.output.trim().isEmpty) continue;
      final artifact = await _store.writeText(
        runId: id,
        name: 'output-${i + 1}',
        kind: VerificationArtifactKind.other,
        label: check.name,
        text: check.output,
        stepOrdinal: i + 1,
        at: finishedAt,
      );
      _dao.insertArtifact(artifact);
    }
    _onChanged();
    return _dao.getRun(id) ?? run;
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
      detail: 'in $workingDirectory ($environmentId)',
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
    _dao.insertRun(run);
    _dao.insertStep(id, step);
    if (output.trim().isNotEmpty) {
      final artifact = await _store.writeText(
        runId: id,
        name: 'output',
        kind: VerificationArtifactKind.other,
        label: line,
        text: output,
        stepOrdinal: 1,
        at: finishedAt,
      );
      _dao.insertArtifact(artifact);
    }
    _onChanged();
    return _dao.getRun(id) ?? run;
  }
}

/// Sortable, unique, and legible in a folder listing: the id a verification
/// run's directory is named by.
String verificationRunId(DateTime now) {
  final at = now.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return 'run-${at.year}${two(at.month)}${two(at.day)}'
      '-${two(at.hour)}${two(at.minute)}${two(at.second)}'
      '-${at.millisecond.toString().padLeft(3, '0')}';
}
