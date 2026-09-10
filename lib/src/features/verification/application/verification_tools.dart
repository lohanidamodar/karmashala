import 'dart:convert';

import 'package:path/path.dart' as p;

import '../domain/verification_artifact.dart';
import '../domain/verification_run.dart';
import '../domain/verification_step.dart';
import '../domain/verification_target.dart';
import 'verification_service.dart';

/// The `verification_*` tools an agent sees, mapped onto [VerificationService].
/// One text block, not a JSON map the bridge would pretty-print, and pruned by
/// default: step detail, file contents and screenshots are opt-in.
class VerificationTools {
  const VerificationTools(this._service, {this.callerSessionId});

  final VerificationService _service;

  /// The calling agent's session; null outside one, and the run stays
  /// unattributed.
  final String? callerSessionId;

  /// Whether [tool] belongs to this set.
  static bool handles(String tool) => tool.startsWith('verification_');

  Future<Object?> call(String tool, Map<String, dynamic> args) async {
    switch (tool) {
      case 'verification_start':
        return _start(args);
      case 'verification_note':
        return _note(args);
      case 'verification_finish':
        return _finish(args);
      case 'verification_list':
        return _list(args);
      case 'verification_get':
        return _get(args);
      default:
        throw VerificationException('Unknown verification tool: $tool');
    }
  }

  Future<Object?> _start(Map<String, dynamic> args) async {
    final url = _string(args['url']);
    final serial = _string(args['serial']);
    final package = _string(args['package']);
    final isChange = args['change'] == true;
    if (url == null && serial == null && !isChange) {
      throw const VerificationException(
        'Give url (to verify a page), serial (to verify a device), or '
        'change:true (to record a review of the code itself). list_devices '
        'has the serials.',
      );
    }
    // Counted, not compared pairwise: a run verifies exactly one thing.
    if ([url != null, serial != null, isChange].where((set) => set).length > 1) {
      throw const VerificationException(
        'A run verifies one thing: pass url, serial or change, not several.',
      );
    }
    final target = isChange
        ? const VerificationTarget.change()
        : url != null
        ? VerificationTarget.browser(url)
        : VerificationTarget.device(serial: serial!, packageName: package);

    // `sessionId` is whose work is verified, the caller is who verifies; equal
    // by default, which is the self-graded case attribution exposes.
    final subjectSessionId = _string(args['sessionId']) ?? callerSessionId;
    final run = await _service.start(
      target: target,
      title: _string(args['title']),
      sessionId: subjectSessionId,
      producedBySessionId: callerSessionId,
      launch: args['launch'] != false,
    );
    return _text([
      'Recording ${run.id} — ${run.title}',
      'Target: ${run.target.kind.label} · ${run.target.label}',
      if (run.sessionId != null) 'Attached to session ${run.sessionId}',
      'Verifier: ${run.producedBySessionId ?? 'not recorded'} '
          '(${run.attribution.shortLabel})',
      '',
      switch (target.kind) {
        VerificationTargetKind.browser =>
          'Every browser_* call is now a step, with its screenshots. Console '
              'errors and failed requests are being collected without being '
              'asked for.',
        VerificationTargetKind.device =>
          'Every device_* call is now a step, with its screenshots. The '
              'closing logcat slice and UI tree are collected for you.',
        VerificationTargetKind.change =>
          'Nothing is being driven and nothing is collected for you: this run '
              'records what you read. Write each finding as a '
              'verification_note as you reach it.',
      },
      target.isChange
          ? 'Then verification_finish with a verdict and a reason — including '
                'when you find nothing, which is a pass and not silence.'
          : 'Drive the change, then verification_finish with a verdict and a '
                'reason.',
    ]);
  }

  Future<Object?> _note(Map<String, dynamic> args) async {
    final text = _string(args['text']);
    if (text == null) {
      throw const VerificationException('text is required.');
    }
    _service.note(text, detail: _string(args['detail']));
    final run = _service.activeRun;
    return _text(['Noted on ${run?.id ?? 'the run'}: $text']);
  }

  Future<Object?> _finish(Map<String, dynamic> args) async {
    final verdict = VerificationVerdict.parse(_string(args['verdict']));
    if (verdict == null) {
      throw const VerificationException(
        'verdict must be one of: pass, fail, inconclusive.',
      );
    }
    final run = await _service.finish(
      verdict: verdict,
      reason: _string(args['reason']),
      producedBySessionId: callerSessionId,
    );
    final report = p.join(run.artifactDirectory, 'report.md');
    return _text([
      '${_verdictWord(run)} — ${run.title}, ${run.attribution.phrase}',
      if (run.reason != null) run.reason!,
      '',
      _summaryLines(run).join('\n'),
      '',
      'Report: $report',
      'Artifacts: ${run.artifactDirectory}',
      'Show the human the report, or verification_get(id: "${run.id}", '
          'images: true) to look at the screenshots yourself.',
    ]);
  }

  Future<Object?> _list(Map<String, dynamic> args) async {
    final runs = _service.list(
      limit: _int(args['limit']) ?? 20,
      sessionId: _string(args['sessionId']),
    );
    if (runs.isEmpty) {
      return _text([
        'No verification runs recorded'
            '${args['sessionId'] == null ? '' : ' for that session'}. '
            'Start one with verification_start.',
      ]);
    }
    return _text([
      '${runs.length} run${runs.length == 1 ? '' : 's'}, newest first:',
      'verdict  id  title  [target]  verifier  steps',
      '',
      for (final run in runs) _runLine(run),
      '',
      'verification_get(id: "…") for one of them.',
    ]);
  }

  Future<Object?> _get(Map<String, dynamic> args) async {
    final id = _string(args['id']);
    final run = id == null
        ? (_service.activeRun == null
              ? null
              : _service.get(_service.activeRun!.id))
        : _service.find(id);
    if (run == null) {
      if (id == null) {
        throw const VerificationException(
          'No run is recording, so there is no "current" one. Pass id, or '
          'verification_list to see what has been recorded.',
        );
      }
      final near = _service.matching(id);
      throw VerificationException(
        near.isEmpty
            ? 'No verification run with id (or prefix) "$id".'
            : '"$id" matches ${near.length} runs:\n'
                  '${near.map(_runLine).join('\n')}',
      );
    }

    final full = args['full'] == true;
    final wantImages = full || args['images'] == true;
    final images = run.artifacts.where((a) => a.kind.isImage).toList();

    final lines = <String>[
      '${_verdictWord(run)} — ${run.title}',
      if (run.reason != null) run.reason!,
      'Target: ${run.target.kind.label} · ${run.target.label}',
      if (run.sessionId != null) 'Session: ${run.sessionId}',
      'Verdict ${run.attribution.phrase}'
          '${run.producedBySessionId == null ? '' : ' (${run.producedBySessionId})'}',
      'Started ${run.startedAt.toIso8601String()}'
          '${run.duration == null ? ' (still recording)' : ', took ${_seconds(run.duration!)}'}',
      '',
      'Steps (${run.steps.length}):',
      for (final step in run.steps) _stepLine(step, run, full: full),
    ];

    if (run.artifacts.isEmpty) {
      lines
        ..add('')
        ..add('Nothing was captured.');
    } else {
      lines
        ..add('')
        ..add('Captured (${run.artifacts.length}):');
      for (final artifact in run.artifacts) {
        lines.add(
          '  ${artifact.kind.label}  ${artifact.relativePath}  '
          '(${artifact.sizeLabel})  ${artifact.label}',
        );
      }
    }

    final blocks = <Map<String, Object?>>[];
    if (full) {
      for (final artifact in run.artifacts) {
        if (artifact.kind.isImage) continue;
        if (artifact.kind == VerificationArtifactKind.report) continue;
        final bytes = await _service.readArtifact(artifact);
        if (bytes == null) continue;
        lines
          ..add('')
          ..add('--- ${artifact.label} (${artifact.relativePath}) ---')
          ..add(utf8.decode(bytes, allowMalformed: true).trimRight());
      }
    }

    if (wantImages) {
      for (final image in images) {
        final bytes = await _service.readArtifact(image);
        if (bytes == null) continue;
        blocks.add(_imageBlock(bytes));
      }
    } else if (images.isNotEmpty) {
      lines
        ..add('')
        ..add(
          '${images.length} screenshot${images.length == 1 ? '' : 's'} not '
          'attached. Pass images:true to look at '
          '${images.length == 1 ? 'it' : 'them'}.',
        );
    }
    if (!full && run.artifacts.any((a) => !a.kind.isImage)) {
      lines.add(
        'Pass full:true for step detail and the contents of the evidence files.',
      );
    }
    lines
      ..add('')
      ..add('Report: ${p.join(run.artifactDirectory, 'report.md')}');

    return _content([
      ...blocks,
      {'type': 'text', 'text': lines.join('\n')},
    ]);
  }

  static String _runLine(VerificationRun run) =>
      '${_verdictMark(run).padRight(7)}  ${run.id}  ${run.title}  '
      '[${run.target.label}]  ${run.attribution.shortLabel}  '
      '${run.steps.length} step${run.steps.length == 1 ? '' : 's'}';

  String _stepLine(
    VerificationStep step,
    VerificationRun run, {
    required bool full,
  }) {
    final files = run.artifacts
        .where((a) => a.stepOrdinal == step.ordinal)
        .map((a) => a.relativePath)
        .join(', ');
    final head =
        '  ${step.ordinal}. ${step.ok ? '' : 'FAILED: '}${step.summary}'
        '${files.isEmpty ? '' : '  → $files'}';
    if (!full || (step.detail ?? '').isEmpty) return head;
    return '$head\n${step.detail!.split('\n').map((l) => '     $l').join('\n')}';
  }

  static List<String> _summaryLines(VerificationRun run) {
    final images = run.artifacts.where((a) => a.kind.isImage).length;
    final console = run.artifacts
        .where((a) => a.kind == VerificationArtifactKind.consoleErrors)
        .length;
    final network = run.artifacts
        .where((a) => a.kind == VerificationArtifactKind.networkFailures)
        .length;
    return [
      '${run.steps.length} step${run.steps.length == 1 ? '' : 's'}, '
          '$images screenshot${images == 1 ? '' : 's'}, '
          '${run.artifacts.length} artifact'
          '${run.artifacts.length == 1 ? '' : 's'}'
          '${run.duration == null ? '' : ', ${_seconds(run.duration!)}'}',
      if (console > 0 || network > 0)
        'The page complained: see the console and network files.',
    ];
  }

  static String _verdictWord(VerificationRun run) => switch (run.verdict) {
    VerificationVerdict.pass => 'PASS',
    VerificationVerdict.fail => 'FAIL',
    VerificationVerdict.inconclusive => 'INCONCLUSIVE',
    null => 'STILL RECORDING',
  };

  static String _verdictMark(VerificationRun run) => switch (run.verdict) {
    VerificationVerdict.pass => 'pass',
    VerificationVerdict.fail => 'FAIL',
    VerificationVerdict.inconclusive => '?',
    null => 'open',
  };

  static String _seconds(Duration d) => d.inSeconds >= 60
      ? '${d.inMinutes}m${d.inSeconds % 60}s'
      : '${d.inSeconds}s';

  static Map<String, Object?> _imageBlock(List<int> bytes) => {
    'type': 'image',
    'data': base64Encode(bytes),
    'mimeType': 'image/png',
  };

  /// One text block. Deliberately not a JSON map — see the class doc.
  static Object _text(List<String> lines) => _content([
    {'type': 'text', 'text': lines.join('\n')},
  ]);

  static Object _content(List<Map<String, Object?>> blocks) => {
    '_mcpContent': blocks,
  };

  static String? _string(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static int? _int(Object? value) => (value as num?)?.round();
}
