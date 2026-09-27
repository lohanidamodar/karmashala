import 'dart:io';

import 'package:karmashala/src/features/verification/application/verification_service.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'verification_harness.dart';

/// The app's side of verification: it reads, exports, attaches and deletes
/// the runs the server records (slice 4a — a device run is the server's too,
/// `server/test/mcp/tools/verification_tool_set_test.dart`).
void main() {
  late VerificationHarness h;

  setUp(() async => h = await VerificationHarness.start());
  tearDown(() => h.dispose());

  test(
    'an ambiguous prefix resolves to nothing; an exact id finds its run',
    () async {
      await h.record(
        target: const VerificationTarget.device(
          serial: 'FAKE123',
          packageName: 'com.example.a',
        ),
      );
      await h.record();

      expect(
        (await h.service.find('run-001'))!.target.packageName,
        'com.example.a',
      );
      expect(await h.service.find('run-'), isNull);
    },
  );

  test('deleting a run removes its files as well as its rows', () async {
    final run = await h.record();
    expect(Directory(run.artifactDirectory).existsSync(), isTrue);

    await h.service.delete(run.id);

    expect(await h.service.get(run.id), isNull);
    expect(Directory(run.artifactDirectory).existsSync(), isFalse);
  });

  test(
    'export writes the report beside the artifacts, evidence inlined',
    () async {
      final run = await h.record(
        reason: 'the row appeared and the log stayed quiet',
        steps: ['clicked save'],
        texts: {VerificationArtifactKind.logcat: 'E MainActivity: boom'},
      );

      final path = await h.service.export(run.id);

      expect(path, p.join(run.artifactDirectory, 'report.md'));
      final text = File(path).readAsStringSync();
      expect(text, contains('# Verification: the save button saves'));
      expect(text, contains('**Verdict: PASS**'));
      expect(text, contains('the row appeared'));
      expect(text, contains('boom'));
    },
  );

  test('exporting a run nobody has is refused in words', () async {
    await expectLater(
      h.service.export('nope'),
      throwsA(
        isA<VerificationException>().having(
          (e) => e.message,
          'message',
          contains('nope'),
        ),
      ),
    );
  });

  test('attaching a run to a session is written and signalled', () async {
    final run = await h.record();
    var bumps = 0;
    final listening = h.changes.stream.listen((_) => bumps++);
    addTearDown(listening.cancel);

    await h.service.attachToSession(run.id, 's1');
    await pumpEventQueue();

    expect((await h.service.get(run.id))!.sessionId, 's1');
    expect(bumps, greaterThan(0));
  });

  test('an artifact is read back from where the server wrote it', () async {
    final run = await h.record(
      texts: {VerificationArtifactKind.uiTree: '<hierarchy/>'},
    );
    final tree = run.artifacts.single;
    expect(h.service.pathOf(tree), h.pathIn(run, tree));
    expect(
      String.fromCharCodes((await h.service.readArtifact(tree))!),
      '<hierarchy/>',
    );
  });
}
