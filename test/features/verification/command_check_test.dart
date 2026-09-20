import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/verification/domain/verification_run.dart';
import 'package:karmashala/src/features/verification/domain/verification_target.dart';
import 'package:path/path.dart' as p;

import 'verification_harness.dart';

/// The gates the app runs itself: one command, one exit code, one verdict.
void main() {
  late VerificationHarness h;

  final startedAt = DateTime.utc(2026, 9, 9, 10);

  setUp(() => h = VerificationHarness());
  tearDown(() => h.dispose());

  Future<VerificationRun> record({
    int? exitCode = 0,
    String output = '',
    String? sessionId,
  }) => h.service.recordCommandCheck(
    title: 'flutter analyze · /home/me/app',
    command: const ['/home/me/flutter/bin/flutter', 'analyze'],
    workingDirectory: '/home/me/app',
    environmentId: 'wsl:Ubuntu',
    startedAt: startedAt,
    exitCode: exitCode,
    output: output,
    sessionId: sessionId,
    producedBySessionId: sessionId,
  );

  test(
    'exit 0 is a pass, and the run is closed the moment it is written',
    () async {
      final run = await record();
      expect(run.verdict, VerificationVerdict.pass);
      expect(run.isOpen, isFalse);
      expect(run.startedAt, startedAt);
      expect(run.finishedAt, isNotNull);
      expect(run.reason, contains('passed'));
    },
  );

  test('a non-zero exit is a fail, and the code is in the reason', () async {
    final run = await record(exitCode: 3);
    expect(run.verdict, VerificationVerdict.fail);
    expect(run.reason, contains('exited 3'));
    expect(run.steps.single.ok, isFalse);
  });

  test('an exit nobody observed is inconclusive, never a pass', () async {
    final run = await record(exitCode: null);
    expect(run.verdict, VerificationVerdict.inconclusive);
    expect(run.reason, contains('unknown'));
  });

  test('the command and where it ran are the run\'s one step', () async {
    final run = await record();
    final step = run.steps.single;
    expect(step.ordinal, 1);
    expect(step.summary, '/home/me/flutter/bin/flutter analyze');
    expect(step.detail, 'in /home/me/app (wsl:Ubuntu)');
  });

  test('the output is kept as an artifact beside the verdict', () async {
    final run = await record(output: 'info • Unused import • lib/a.dart:3');
    final artifact = run.artifacts.single;
    expect(artifact.stepOrdinal, 1);
    final file = File(p.join(run.artifactDirectory, artifact.relativePath));
    expect(file.readAsStringSync(), contains('Unused import'));
  });

  test('a gate that printed nothing writes no artifact', () async {
    expect((await record(output: '   \n')).artifacts, isEmpty);
  });

  test('it is addressless, like every change-shaped run', () async {
    expect((await record()).target.kind, VerificationTargetKind.change);
  });

  test('it does not take the recording slot an agent\'s run needs', () async {
    final open = await h.service.start(
      target: const VerificationTarget.change(),
      title: 'the list scrolls',
    );
    // A gate mid-review is the ordinary case, and it must neither be refused
    // nor clobber what is being recorded.
    final gate = await record();
    expect(gate.verdict, VerificationVerdict.pass);
    expect(h.service.activeRun!.id, open.id);
    expect(h.service.activeRun!.isOpen, isTrue);
  });

  test('it is listed with everything else', () async {
    final gate = await record();
    expect(h.service.list().map((run) => run.id), contains(gate.id));
    expect(h.service.get(gate.id)!.verdict, VerificationVerdict.pass);
  });
}
