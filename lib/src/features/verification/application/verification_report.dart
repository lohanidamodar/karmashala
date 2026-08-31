import '../domain/verification_artifact.dart';
import '../domain/verification_run.dart';
import '../domain/verification_step.dart';

/// Renders a run as one markdown document.
///
/// Written to be **pasted**: into a pull request, into a prompt, into a message
/// to whoever asked whether the change works. Image links are relative to the
/// run's own directory, so the folder is the unit that moves — copy it anywhere
/// and the pictures still resolve.
///
/// [inlined] carries the contents of the small text artifacts (console errors,
/// the log slice) keyed by relative path. Anything not in it is linked instead,
/// which is what keeps a 200-line logcat out of a report meant to be read.
String renderVerificationReport(
  VerificationRun run, {
  Map<String, String> inlined = const {},
  String? sessionTitle,
}) {
  final out = StringBuffer()
    ..writeln('# Verification: ${run.title}')
    ..writeln();

  if (run.verdict == null) {
    out.writeln('**Verdict: still open** — this run was never finished.');
  } else {
    final mark = switch (run.verdict!) {
      VerificationVerdict.pass => 'PASS',
      VerificationVerdict.fail => 'FAIL',
      VerificationVerdict.inconclusive => 'INCONCLUSIVE',
    };
    out.write('**Verdict: $mark**');
    out.writeln(
      run.reason == null || run.reason!.trim().isEmpty
          ? ' — no reason was given.'
          : ' — ${run.reason!.trim()}',
    );
  }
  out.writeln();

  out
    ..writeln('| | |')
    ..writeln('| --- | --- |')
    ..writeln('| Target | ${run.target.kind.label} · `${run.target.label}` |');
  if (run.target.isDevice && run.target.packageName != null) {
    out.writeln('| Package | `${run.target.packageName}` |');
  }
  if (run.sessionId != null) {
    out.writeln(
      '| Session | ${sessionTitle ?? '(untitled)'} '
      '(`${run.sessionId}`) |',
    );
  }
  // Who graded it, on the same table as what was graded: a report that says
  // PASS without saying who decided is the self-graded exam G3 names.
  out.writeln(
    '| Verifier | ${run.attribution.label}'
    '${run.producedBySessionId == null ? '' : ' (`${run.producedBySessionId}`)'} |',
  );
  out
    ..writeln('| Started | ${run.startedAt.toIso8601String()} |')
    ..writeln(
      '| Duration | ${run.duration == null ? '—' : _duration(run.duration!)} |',
    )
    ..writeln('| Steps | ${run.steps.length} |')
    ..writeln('| Run id | `${run.id}` |')
    ..writeln();

  out
    ..writeln('## What was done')
    ..writeln();
  if (run.steps.isEmpty) {
    out.writeln('_Nothing was recorded._');
  } else {
    for (final step in run.steps) {
      final artifacts = run.artifacts
          .where((a) => a.stepOrdinal == step.ordinal)
          .toList();
      out.write(
        '${step.ordinal}. **${step.kind.label}**'
        '${step.ok ? '' : ' — FAILED'} · `${_clock(step.at)}` — '
        '${_escape(step.summary)}',
      );
      if (artifacts.isNotEmpty) {
        out.write(
          ' '
          '${artifacts.map((a) => '[${a.kind.label.toLowerCase()}]'
              '(${a.relativePath})').join(' ')}',
        );
      }
      out.writeln();
      if (step.detail != null && step.detail!.trim().isNotEmpty) {
        for (final line in step.detail!.trim().split('\n')) {
          out.writeln('   > ${_escape(line)}');
        }
      }
    }
  }
  out.writeln();

  final images = run.artifacts.where((a) => a.kind.isImage).toList();
  final texts = run.artifacts.where((a) => !a.kind.isImage).toList();

  if (images.isNotEmpty) {
    out
      ..writeln('## Screenshots')
      ..writeln();
    for (final image in images) {
      out
        ..writeln('**${_escape(image.label)}** (${image.sizeLabel})')
        ..writeln()
        ..writeln('![${_escape(image.label)}](${image.relativePath})')
        ..writeln();
    }
  }

  if (texts.isNotEmpty) {
    out
      ..writeln('## Evidence')
      ..writeln();
    for (final artifact in texts) {
      out.writeln('### ${artifact.kind.label} — ${_escape(artifact.label)}');
      out.writeln();
      final body = inlined[artifact.relativePath];
      if (body == null) {
        out
          ..writeln(
            '[${artifact.relativePath}](${artifact.relativePath}) '
            '(${artifact.sizeLabel})',
          )
          ..writeln();
      } else {
        out
          ..writeln('```')
          ..writeln(body.trimRight())
          ..writeln('```')
          ..writeln();
      }
    }
  }

  out
    ..writeln('---')
    ..writeln()
    ..writeln(
      'Recorded by Chitragupta. Files are in `${run.artifactDirectory}`.',
    );
  return out.toString();
}

String _duration(Duration d) {
  if (d.inMinutes >= 1) {
    return '${d.inMinutes} min ${d.inSeconds.remainder(60)} s';
  }
  if (d.inSeconds >= 1) return '${d.inSeconds} s';
  return '${d.inMilliseconds} ms';
}

String _clock(DateTime at) {
  final local = at.toLocal();
  return '${_two(local.hour)}:${_two(local.minute)}:${_two(local.second)}';
}

String _two(int value) => value.toString().padLeft(2, '0');

/// Keeps a summary from breaking the list it sits in. Pipes matter because
/// summaries also land in the table above.
String _escape(String value) =>
    value.replaceAll('\n', ' ').replaceAll('|', r'\|');

/// The step kinds that carry a payload worth reading in full.
extension VerificationStepReport on VerificationStep {
  bool get hasDetail => detail != null && detail!.trim().isNotEmpty;
}

/// Whether an artifact is small enough to paste into the report rather than
/// link. 8 KB is about 100 lines of log — past that a reader wants the file.
bool shouldInline(VerificationArtifact artifact) =>
    !artifact.kind.isImage && artifact.byteSize <= 8 * 1024;
