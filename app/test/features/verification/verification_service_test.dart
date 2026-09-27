import 'dart:convert';
import 'dart:io';

import 'package:karmashala/src/features/verification/application/verification_service.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'verification_harness.dart';

/// The app's verification runs drive a device on its machine; a page run is
/// the server's since slice 3d (`server/test/mcp/tools/verification_*`).
void main() {
  late VerificationHarness h;

  setUp(() async => h = await VerificationHarness.start());
  tearDown(() => h.dispose());

  const device = VerificationTarget.device(
    serial: 'FAKE123',
    packageName: 'com.example.app',
  );

  group('starting', () {
    test('a page run is the server\'s, and is refused here in words', () async {
      await expectLater(
        h.service.start(
          target: const VerificationTarget.browser('https://example.com'),
        ),
        throwsA(
          isA<VerificationException>().having(
            (e) => e.message,
            'message',
            contains('verified by the Karmashala server'),
          ),
        ),
      );
      expect(h.service.activeRun, isNull);
    });

    test('a device run launches the package as its first step', () async {
      final run = await h.service.start(target: device);

      expect(h.adb.called('monkey -p com.example.app'), isTrue);
      final steps = (await h.service.get(run.id))!.steps;
      expect(steps.first.kind, VerificationStepKind.launch);
      expect(steps.first.summary, contains('com.example.app'));
    });

    test('launch:false verifies what is already on screen', () async {
      await h.service.start(target: device, launch: false);

      expect(h.adb.called('monkey'), isFalse);
    });

    test(
      'a package with no launcher activity is reported, not guessed at',
      () async {
        h.adb.packageInstalled = false;

        await expectLater(
          h.service.start(
            target: const VerificationTarget.device(
              serial: 'FAKE123',
              packageName: 'com.nope',
            ),
          ),
          throwsA(isA<StateError>()),
        );
        // The run survives the failure, with the reason recorded.
        final run = h.service.activeRun!;
        final steps = (await h.service.get(run.id))!.steps;
        expect(steps.last.summary, contains('Could not reach the target'));
      },
    );

    test('a second run is refused while the first is recording', () async {
      await h.service.start(target: device, launch: false);

      await expectLater(
        h.service.start(target: device, launch: false),
        throwsA(
          isA<VerificationException>().having(
            (e) => e.message,
            'message',
            contains('already recording'),
          ),
        ),
      );
    });

    test('a device with an unknown serial is named, not assumed', () async {
      await expectLater(
        h.service.start(
          target: const VerificationTarget.device(serial: 'NOT-HERE'),
        ),
        throwsA(
          isA<VerificationException>().having(
            (e) => e.message,
            'message',
            contains('NOT-HERE'),
          ),
        ),
      );
    });
  });

  group('recording', () {
    test(
      'device actions become steps, and the UI tree becomes a file',
      () async {
        final run = await h.service.start(target: device);
        await h.adb.service.tap('FAKE123', 100, 200);
        await h.adb.service.dumpUiHierarchy('FAKE123');
        h.service.note('the header is where it should be');
        await h.service.flush();

        final recorded = (await h.service.get(run.id))!;
        expect(
          recorded.steps.map((s) => s.summary),
          containsAll([
            'Tapped (100, 200)',
            'the header is where it should be',
          ]),
        );
        final tree = recorded.artifacts.firstWhere(
          (a) => a.kind == VerificationArtifactKind.uiTree,
        );
        expect(
          File(
            p.join(recorded.artifactDirectory, tree.relativePath),
          ).readAsStringSync(),
          contains('Settings'),
        );
      },
    );

    test('nothing is recorded once the run is finished', () async {
      final run = await h.service.start(target: device, launch: false);
      await h.service.finish(verdict: VerificationVerdict.pass);
      final before = (await h.service.get(run.id))!.steps.length;

      await h.adb.service.tap('FAKE123', 1, 1);
      await h.service.flush();

      expect((await h.service.get(run.id))!.steps, hasLength(before));
      expect(h.adb.service.actionSink, isNull);
    });
  });

  group('finishing', () {
    test(
      'records the verdict and writes a report beside the artifacts',
      () async {
        final run = await h.service.start(
          target: device,
          title: 'the save button saves',
          launch: false,
        );
        h.service.note('clicked save');

        final finished = await h.service.finish(
          verdict: VerificationVerdict.pass,
          reason: 'the row appeared and the log stayed quiet',
        );

        expect(finished.verdict, VerificationVerdict.pass);
        expect(finished.reason, 'the row appeared and the log stayed quiet');
        expect(finished.isOpen, isFalse);
        expect(h.service.activeRun, isNull);

        final report = File(p.join(run.artifactDirectory, 'report.md'));
        expect(report.existsSync(), isTrue);
        final text = report.readAsStringSync();
        expect(text, contains('# Verification: the save button saves'));
        expect(text, contains('**Verdict: PASS**'));
        expect(text, contains('the row appeared'));
      },
    );

    test('a device run closes with a logcat slice and a UI tree', () async {
      final finished = await h.service
          .start(target: device)
          .then(
            (_) => h.service.finish(
              verdict: VerificationVerdict.pass,
              reason: 'the screen shows Settings',
            ),
          );

      expect(
        finished.artifacts.map((a) => a.kind),
        containsAll([
          VerificationArtifactKind.logcat,
          VerificationArtifactKind.uiTree,
          VerificationArtifactKind.screenshot,
        ]),
      );
      final logcat = finished.artifacts.firstWhere(
        (a) => a.kind == VerificationArtifactKind.logcat,
      );
      expect(
        utf8.decode((await h.service.readArtifact(logcat))!),
        contains('boom'),
      );
    });

    test(
      'an app that was not running says so instead of an empty file',
      () async {
        h.adb.packageRunning = false;
        await h.service.start(target: device);
        final finished = await h.service.finish(
          verdict: VerificationVerdict.inconclusive,
        );

        expect(
          finished.steps.map((s) => s.summary).join('\n'),
          contains('not running'),
        );
      },
    );

    test(
      'finishing with nothing recording is refused with a way forward',
      () async {
        await expectLater(
          h.service.finish(verdict: VerificationVerdict.pass),
          throwsA(
            isA<VerificationException>().having(
              (e) => e.message,
              'message',
              contains('verification_start'),
            ),
          ),
        );
      },
    );
  });

  group('reading', () {
    test(
      'an ambiguous prefix resolves to nothing, and lists the candidates',
      () async {
        await h.service.start(
          target: const VerificationTarget.device(
            serial: 'FAKE123',
            packageName: 'com.example.a',
          ),
          launch: false,
        );
        await h.service.finish(verdict: VerificationVerdict.pass);
        await h.service.start(target: device, launch: false);
        await h.service.finish(verdict: VerificationVerdict.pass);

        expect(
          (await h.service.find('run-001'))!.target.packageName,
          'com.example.a',
        );
        expect((await h.service.find('run-')), isNull);
        expect((await h.service.matching('run-')), hasLength(2));
      },
    );

    test('deleting a run removes its files as well as its rows', () async {
      final run = await h.service.start(target: device, launch: false);
      await h.service.finish(verdict: VerificationVerdict.pass);
      expect(Directory(run.artifactDirectory).existsSync(), isTrue);

      await h.service.delete(run.id);

      expect((await h.service.get(run.id)), isNull);
      expect(Directory(run.artifactDirectory).existsSync(), isFalse);
    });

    test('abandoning leaves the run open and takes the sink off', () async {
      final run = await h.service.start(target: device, launch: false);
      await h.service.abandon();

      expect(h.service.activeRun, isNull);
      expect((await h.service.get(run.id))!.isOpen, isTrue);
      expect(h.adb.service.actionSink, isNull);
    });
  });
}
