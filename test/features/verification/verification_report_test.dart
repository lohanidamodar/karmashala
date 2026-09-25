import 'package:karmashala/src/features/verification/application/verification_report.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:flutter_test/flutter_test.dart';

final _t0 = DateTime.utc(2026, 8, 30, 12);

VerificationRun _run({
  VerificationTarget? target,
  VerificationVerdict? verdict,
  String? reason,
  String? sessionId,
  List<VerificationStep> steps = const [],
  List<VerificationArtifact> artifacts = const [],
}) => VerificationRun(
  id: 'run-20260830-120000-000',
  title: 'the settings page saves on Enter',
  target: target ?? const VerificationTarget.browser('http://localhost:3000'),
  sessionId: sessionId,
  startedAt: _t0,
  finishedAt: verdict == null ? null : _t0.add(const Duration(seconds: 12)),
  verdict: verdict,
  reason: reason,
  artifactDirectory: r'C:\support\verification\run-20260830-120000-000',
  steps: steps,
  artifacts: artifacts,
);

VerificationStep _step(
  int ordinal,
  String summary, {
  VerificationStepKind kind = VerificationStepKind.click,
  String? detail,
  bool ok = true,
}) => VerificationStep(
  ordinal: ordinal,
  kind: kind,
  summary: summary,
  detail: detail,
  ok: ok,
  at: _t0.add(Duration(seconds: ordinal)),
);

VerificationArtifact _artifact(
  VerificationArtifactKind kind,
  String path, {
  String label = 'evidence',
  int size = 100,
  int? stepOrdinal,
}) => VerificationArtifact(
  id: 'run:$path',
  runId: 'run-20260830-120000-000',
  kind: kind,
  label: label,
  relativePath: path,
  byteSize: size,
  at: _t0,
  stepOrdinal: stepOrdinal,
);

void main() {
  test('the verdict and the reason are the first thing a reader sees', () {
    final markdown = renderVerificationReport(
      _run(
        verdict: VerificationVerdict.pass,
        reason: 'the row appeared and the console stayed quiet',
      ),
    );

    final head = markdown.split('\n').take(5).join('\n');
    expect(head, contains('# Verification: the settings page saves on Enter'));
    expect(head, contains('**Verdict: PASS**'));
    expect(head, contains('the row appeared and the console stayed quiet'));
  });

  test('a run nobody finished says so rather than implying a pass', () {
    final markdown = renderVerificationReport(_run());
    expect(markdown, contains('still open'));
    expect(markdown, isNot(contains('PASS')));
  });

  test('a verdict with no reason admits it', () {
    final markdown = renderVerificationReport(
      _run(verdict: VerificationVerdict.fail),
    );
    expect(markdown, contains('no reason was given'));
  });

  test('steps are numbered in order, with failures marked', () {
    final markdown = renderVerificationReport(
      _run(
        verdict: VerificationVerdict.fail,
        steps: [
          _step(
            1,
            'Navigated to /settings',
            kind: VerificationStepKind.navigate,
          ),
          _step(2, 'Clicked Save'),
          _step(3, 'Clicked Retry', ok: false, detail: 'a banner covered it'),
        ],
      ),
    );

    final body = markdown.substring(markdown.indexOf('## What was done'));
    expect(
      body.indexOf('Navigated to /settings'),
      lessThan(body.indexOf('Clicked Save')),
    );
    expect(body, contains('FAILED'));
    expect(body, contains('a banner covered it'));
  });

  test('image links are relative, so the folder can be copied anywhere', () {
    final markdown = renderVerificationReport(
      _run(
        verdict: VerificationVerdict.pass,
        artifacts: [
          _artifact(
            VerificationArtifactKind.screenshot,
            '001-screenshot.png',
            label: 'The settings page',
          ),
        ],
      ),
    );

    expect(markdown, contains('![The settings page](001-screenshot.png)'));
    expect(markdown, isNot(contains(r'](C:\')));
  });

  test('a small evidence file is inlined; a big one is linked', () {
    final markdown = renderVerificationReport(
      _run(
        verdict: VerificationVerdict.fail,
        artifacts: [
          _artifact(
            VerificationArtifactKind.consoleErrors,
            'console.txt',
            label: '1 console error',
          ),
          _artifact(
            VerificationArtifactKind.logcat,
            'logcat.txt',
            label: '400 log lines',
            size: 90 * 1024,
          ),
        ],
      ),
      inlined: {'console.txt': 'TypeError: save is not a function'},
    );

    expect(markdown, contains('TypeError: save is not a function'));
    expect(markdown, contains('[logcat.txt](logcat.txt)'));
    expect(markdown, contains('90.0 KB'));
  });

  test('a summary with a pipe cannot break the table it lands in', () {
    final markdown = renderVerificationReport(
      _run(
        verdict: VerificationVerdict.pass,
        steps: [_step(1, 'Clicked "Save | Publish"')],
      ),
    );
    expect(markdown, contains(r'Save \| Publish'));
  });

  test('the session is named when there is one, and absent when not', () {
    expect(
      renderVerificationReport(
        _run(verdict: VerificationVerdict.pass, sessionId: 'S1'),
        sessionTitle: 'settings rewrite',
      ),
      contains('settings rewrite'),
    );
    expect(
      renderVerificationReport(_run(verdict: VerificationVerdict.pass)),
      isNot(contains('| Session |')),
    );
  });

  test('a device run names the package it was about', () {
    final markdown = renderVerificationReport(
      _run(
        target: const VerificationTarget.device(
          serial: 'F6IZLV6LMFT4U4ZT',
          packageName: 'com.example.app',
        ),
        verdict: VerificationVerdict.pass,
      ),
    );
    expect(markdown, contains('F6IZLV6LMFT4U4ZT'));
    expect(markdown, contains('com.example.app'));
  });

  test('an empty run is honest about having recorded nothing', () {
    final markdown = renderVerificationReport(
      _run(verdict: VerificationVerdict.inconclusive, reason: 'never loaded'),
    );
    expect(markdown, contains('Nothing was recorded'));
  });

  group('shouldInline', () {
    test('images are never inlined as text', () {
      expect(
        shouldInline(_artifact(VerificationArtifactKind.screenshot, 'a.png')),
        isFalse,
      );
    });

    test('a small log is inlined, a large one is not', () {
      expect(
        shouldInline(
          _artifact(VerificationArtifactKind.logcat, 'a.txt', size: 2000),
        ),
        isTrue,
      );
      expect(
        shouldInline(
          _artifact(VerificationArtifactKind.logcat, 'b.txt', size: 100 * 1024),
        ),
        isFalse,
      );
    });
  });
}
