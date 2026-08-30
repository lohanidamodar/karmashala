import 'dart:convert';

import 'package:path/path.dart' as p;

import '../domain/verification_artifact.dart';
import '../domain/verification_run.dart';
import '../domain/verification_step.dart';
import '../domain/verification_target.dart';
import 'verification_service.dart';

/// The `verification_*` tools an agent sees, mapped onto [VerificationService].
///
/// Same two rules as the browser tools, for the same reasons (Loop 34, Loop 39):
///
/// * **One text block, not a JSON map.** The bridge pretty-prints a map, and a
///   run rendered as JSON costs several times what the same run costs as lines.
/// * **Prune by default.** `verification_get` returns summaries; step detail,
///   file contents and screenshots are opt-in. A run with twelve screenshots is
///   a very expensive default.
class VerificationTools {
  const VerificationTools(this._service);

  final VerificationService _service;

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

  // --- Recording -------------------------------------------------------------

  Future<Object?> _start(Map<String, dynamic> args) async {
    final url = _string(args['url']);
    final serial = _string(args['serial']);
    final package = _string(args['package']);
    if (url == null && serial == null) {
      throw const VerificationException(
        'Give url (to verify a page) or serial (to verify a device). '
        'list_devices has the serials.',
      );
    }
    if (url != null && serial != null) {
      throw const VerificationException(
        'A run verifies one thing: pass url or serial, not both.',
      );
    }
    final target = url != null
        ? VerificationTarget.browser(url)
        : VerificationTarget.device(serial: serial!, packageName: package);

    final run = await _service.start(
      target: target,
      title: _string(args['title']),
      sessionId: _string(args['sessionId']),
      launch: args['launch'] != false,
    );
    return _text([
      'Recording ${run.id} — ${run.title}',
      'Target: ${run.target.kind.label} · ${run.target.label}',
      if (run.sessionId != null) 'Attached to session ${run.sessionId}',
      '',
      target.isBrowser
          ? 'Every browser_* call is now a step, with its screenshots. Console '
                'errors and failed requests are being collected without being '
                'asked for.'
          : 'Every device_* call is now a step, with its screenshots. The '
                'closing logcat slice and UI tree are collected for you.',
      'Drive the change, then verification_finish with a verdict and a reason.',
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
    );
    final report = p.join(run.artifactDirectory, 'report.md');
    return _text([
      '${_verdictWord(run)} — ${run.title}',
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

  // --- Reading ---------------------------------------------------------------

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
      'verdict  id  title  [target]  steps',
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

  // --- Rendering -------------------------------------------------------------

  static String _runLine(VerificationRun run) =>
      '${_verdictMark(run).padRight(7)}  ${run.id}  ${run.title}  '
      '[${run.target.label}]  '
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
