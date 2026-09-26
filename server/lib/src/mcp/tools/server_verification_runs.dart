import 'dart:convert';
import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/store.dart' show AgentInstallationDao;
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session_engine/store.dart' show SessionDao;
import 'package:karmashala_verification/artifacts.dart';
import 'package:karmashala_verification/command_checks.dart'
    show verificationRunId;
import 'package:karmashala_verification/report.dart';
import 'package:karmashala_verification/store.dart' show VerificationDao;
import 'package:karmashala_verification/tools.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:path/path.dart' as p;

import 'server_tool_context.dart';

/// The server's one recording slot: a review of a change, which drives
/// nothing and so needs no desktop. Its rows go through the data API, so every
/// client's copy follows the run; its evidence and report are written under
/// `<data dir>/verification`, where the app's pane reads them.
///
/// A page or a device run is the app's (its browser, its adb), and is never
/// started here — see `VerificationToolSet`.
class ServerVerificationRuns implements VerificationToolBackend {
  ServerVerificationRuns(this._context, {String Function()? newId})
    : _newId = newId,
      _runs = VerificationDao(_context.database),
      _store = VerificationArtifactStore(
        Directory(p.join(_context.dataDirectory, 'verification')),
      );

  final ServerToolContext _context;
  final String Function()? _newId;
  final VerificationDao _runs;
  final VerificationArtifactStore _store;

  VerificationRun? _active;
  var _ordinal = 0;

  @override
  VerificationRun? get activeRun => _active;

  bool get isRecording => _active != null;

  @override
  Future<VerificationRun> start({
    required VerificationTarget target,
    String? title,
    String? sessionId,
    String? producedBySessionId,
    bool launch = true,
  }) async {
    final open = _active;
    if (open != null) {
      throw VerificationException(
        'A verification run is already recording: "${open.title}" '
        '(${open.id}). Finish it before starting another.',
      );
    }
    if (!target.isChange) {
      throw StateError(
        'The server records a review of a change only; a page or a device run '
        'is the app\'s.',
      );
    }
    final id = _newId?.call() ?? verificationRunId(_context.now());
    final directory = await _store.createDirectory(id);
    final run = _context.write(
      VerificationStart(
        VerificationRun(
          id: id,
          title: (title == null || title.trim().isEmpty)
              ? 'Review of the change'
              : title.trim(),
          target: target,
          sessionId: sessionId,
          producedBySessionId: producedBySessionId,
          startedAt: _context.now(),
          artifactDirectory: directory.path,
        ),
      ),
    );
    _active = run;
    _ordinal = 0;
    return run;
  }

  @override
  void note(String text, {String? detail}) {
    final run = _require();
    if (text.trim().isEmpty) {
      throw const VerificationException('A note needs something to say.');
    }
    _context.write(
      VerificationStepAdd(
        run.id,
        VerificationStep(
          ordinal: ++_ordinal,
          kind: VerificationStepKind.note,
          summary: text.trim(),
          detail: detail,
          at: _context.now(),
        ),
      ),
    );
  }

  /// Closes the run, writes its report, and files the verdict in the
  /// decision record of the session whose work it judged.
  @override
  Future<VerificationRun> finish({
    required VerificationVerdict verdict,
    String? reason,
    String? producedBySessionId,
  }) async {
    final run = _require();
    final finished = _context.write(
      VerificationFinish(
        run.id,
        verdict: verdict,
        reason: reason?.trim(),
        producedBySessionId: producedBySessionId,
      ),
    );
    _active = null;
    final whole = _runs.getRun(run.id) ?? finished;
    await _writeReport(whole);
    _recordVerdict(whole);
    return whole;
  }

  @override
  Future<List<VerificationRun>> list({
    int limit = 50,
    String? sessionId,
  }) async => [
    for (final run in _runs.listRuns(limit: limit, sessionId: sessionId))
      run.copyWith(
        steps: _runs.stepsFor(run.id),
        artifacts: _runs.artifactsFor(run.id),
      ),
  ];

  @override
  Future<VerificationRun?> get(String id) async => _runs.getRun(id);

  @override
  Future<VerificationRun?> find(String idOrPrefix) async {
    final exact = _runs.getRun(idOrPrefix);
    if (exact != null) return exact;
    final matches = _runs.findByPrefix(idOrPrefix);
    return matches.length == 1 ? _runs.getRun(matches.single.id) : null;
  }

  @override
  Future<List<VerificationRun>> matching(String prefix) async =>
      _runs.findByPrefix(prefix);

  @override
  Future<List<int>?> readArtifact(VerificationArtifact artifact) =>
      _store.read(artifact);

  Future<void> _writeReport(VerificationRun run) async {
    final inlined = <String, String>{};
    for (final artifact in run.artifacts) {
      if (!shouldInline(artifact)) continue;
      final bytes = await _store.read(artifact);
      if (bytes == null) continue;
      inlined[artifact.relativePath] = utf8.decode(bytes, allowMalformed: true);
    }
    try {
      final file = File(p.join(run.artifactDirectory, 'report.md'));
      await file.parent.create(recursive: true);
      await file.writeAsString(
        renderVerificationReport(run, inlined: inlined),
        flush: true,
      );
    } on FileSystemException catch (error) {
      _context.log('the report of ${run.id} could not be written ($error)');
    }
  }

  /// The verdict in the **subject** session's record, not the verifier's; an
  /// unattached run writes nothing. Best-effort, as the app's was.
  void _recordVerdict(VerificationRun run) {
    final subject = run.sessionId;
    final verdict = run.verdict;
    if (subject == null || verdict == null) return;
    final reason = run.reason;
    final producer = run.producedBySessionId;
    try {
      _context.write(
        DecisionAppend(
          DecisionRecord(
            sessionId: subject,
            kind: DecisionKind.verificationVerdict,
            summary: reason == null || reason.trim().isEmpty
                ? '${verdict.label} — ${run.title}'
                : '${verdict.label} — ${run.title}. $reason',
            detail: 'Verdict ${run.attribution.phrase}.',
            decidedBy: producer == null ? null : _agentNameFor(producer),
            recordedBySessionId: producer,
            origin: DecisionOrigin.verificationRun,
            originId: run.id,
            recordedAt: _context.now(),
          ),
        ),
      );
    } on Object catch (error) {
      _context.log(
        'the verdict of ${run.id} could not be recorded for $subject ($error)',
      );
    }
  }

  /// The display name of the agent running [sessionId], or null — never a
  /// guess.
  String? _agentNameFor(String sessionId) {
    final session = SessionDao(_context.database).getById(sessionId);
    if (session == null) return null;
    final agentId = AgentInstallationDao(
      _context.database,
    ).getById(session.agentInstallationId)?.agentId;
    return agentId == null ? null : _context.agents.displayNameFor(agentId);
  }

  VerificationRun _require() =>
      _active ??
      (throw const VerificationException(
        'No verification run is recording. Call verification_start first.',
      ));
}
