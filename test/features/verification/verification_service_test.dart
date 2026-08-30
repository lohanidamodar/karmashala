import 'dart:convert';
import 'dart:io';

import 'package:chitragupta/src/features/verification/application/verification_service.dart';
import 'package:chitragupta/src/features/verification/domain/verification_artifact.dart';
import 'package:chitragupta/src/features/verification/domain/verification_run.dart';
import 'package:chitragupta/src/features/verification/domain/verification_step.dart';
import 'package:chitragupta/src/features/verification/domain/verification_target.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'verification_harness.dart';

/// Lets the observer's CDP listeners run. Steps are already durable when the
/// call that produced them returns; the recorder's file writes are drained with
/// `service.flush()`.
Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  late VerificationHarness h;

  setUp(() => h = VerificationHarness());
  tearDown(() => h.dispose());

  group('starting', () {
    test('a browser run attaches, navigates and starts watching', () async {
      final run = await h.service.start(
        target: const VerificationTarget.browser('https://example.com/app'),
        title: 'the settings page saves',
      );

      expect(run.title, 'the settings page saves');
      expect(run.isOpen, isTrue);
      expect(h.service.activeRun!.id, run.id);
      expect(h.browser.service.isConnected, isTrue);
      expect(h.browser.service.observer, isNotNull);
      // The navigation is the run's first step, not a silent prelude.
      expect(
        h.service.get(run.id)!.steps.map((s) => s.kind),
        contains(VerificationStepKind.navigate),
      );
    });

    test('a device run launches the package as its first step', () async {
      final run = await h.service.start(
        target: const VerificationTarget.device(
          serial: 'FAKE123',
          packageName: 'com.example.app',
        ),
      );

      expect(h.adb.called('monkey -p com.example.app'), isTrue);
      final steps = h.service.get(run.id)!.steps;
      expect(steps.first.kind, VerificationStepKind.launch);
      expect(steps.first.summary, contains('com.example.app'));
    });

    test('launch:false verifies what is already on screen', () async {
      await h.service.start(
        target: const VerificationTarget.device(
          serial: 'FAKE123',
          packageName: 'com.example.app',
        ),
        launch: false,
      );

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
        final steps = h.service.get(run.id)!.steps;
        expect(steps.last.summary, contains('Could not reach the target'));
      },
    );

    test('a second run is refused while the first is recording', () async {
      await h.service.start(
        target: const VerificationTarget.browser('https://example.com'),
      );

      await expectLater(
        h.service.start(
          target: const VerificationTarget.browser('https://other.test'),
        ),
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
    test('browser actions become steps with their screenshots', () async {
      final run = await h.service.start(
        target: const VerificationTarget.browser('https://example.com'),
      );
      await h.browser.service.screenshot();
      h.service.note('the header is where it should be');
      await h.service.flush();

      final recorded = h.service.get(run.id)!;
      expect(
        recorded.steps.map((s) => s.kind),
        containsAll([
          VerificationStepKind.screenshot,
          VerificationStepKind.note,
        ]),
      );
      final shot = recorded.artifacts.firstWhere((a) => a.kind.isImage);
      expect(
        File(
          p.join(recorded.artifactDirectory, shot.relativePath),
        ).existsSync(),
        isTrue,
      );
    });

    test(
      'device actions become steps, and the UI tree becomes a file',
      () async {
        final run = await h.service.start(
          target: const VerificationTarget.device(
            serial: 'FAKE123',
            packageName: 'com.example.app',
          ),
        );
        await h.adb.service.tap('FAKE123', 100, 200);
        await h.adb.service.dumpUiHierarchy('FAKE123');
        await h.service.flush();

        final recorded = h.service.get(run.id)!;
        expect(
          recorded.steps.map((s) => s.summary),
          contains('Tapped (100, 200)'),
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

    test(
      'a failed action is recorded as a failed step, and still throws',
      () async {
        final run = await h.service.start(
          target: const VerificationTarget.browser('https://example.com'),
        );
        h.browser.onEvaluate = (expression) =>
            expression.contains('__chitragupta') ? null : null;

        await expectLater(
          h.browser.service.click(selector: '#nothing'),
          throwsA(anything),
        );
        await h.service.flush();

        final failed = h.service
            .get(run.id)!
            .steps
            .where((s) => !s.ok)
            .toList();
        expect(failed, isNotEmpty);
        expect(failed.last.kind, VerificationStepKind.click);
        expect(failed.last.detail, isNotNull);
      },
    );

    test('nothing is recorded once the run is finished', () async {
      final run = await h.service.start(
        target: const VerificationTarget.browser('https://example.com'),
      );
      await h.service.finish(verdict: VerificationVerdict.pass);
      final before = h.service.get(run.id)!.steps.length;

      await h.browser.service.screenshot();
      await h.service.flush();

      expect(h.service.get(run.id)!.steps, hasLength(before));
      expect(h.browser.service.actionSink, isNull);
    });
  });

  group('finishing', () {
    test(
      'records the verdict and writes a report beside the artifacts',
      () async {
        final run = await h.service.start(
          target: const VerificationTarget.browser('https://example.com'),
          title: 'the save button saves',
        );
        h.service.note('clicked save');

        final finished = await h.service.finish(
          verdict: VerificationVerdict.pass,
          reason: 'the row appeared and the console stayed quiet',
        );

        expect(finished.verdict, VerificationVerdict.pass);
        expect(
          finished.reason,
          'the row appeared and the console stayed quiet',
        );
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

    test(
      'console errors seen during the run are collected without asking',
      () async {
        final run = await h.service.start(
          target: const VerificationTarget.browser('https://example.com'),
        );
        h.browser.socket.emitEvent('Runtime.consoleAPICalled', {
          'type': 'error',
          'args': [
            {'type': 'string', 'value': 'TypeError: save is not a function'},
          ],
        });
        h.browser.socket.emitEvent('Network.requestWillBeSent', {
          'requestId': 'R1',
          'request': {'method': 'POST', 'url': 'https://api.test/save'},
        });
        h.browser.socket.emitEvent('Network.responseReceived', {
          'requestId': 'R1',
          'response': {'url': 'https://api.test/save', 'status': 500},
        });
        await settle();

        final finished = await h.service.finish(
          verdict: VerificationVerdict.fail,
          reason: 'save throws',
        );

        final console = finished.artifacts.firstWhere(
          (a) => a.kind == VerificationArtifactKind.consoleErrors,
        );
        final network = finished.artifacts.firstWhere(
          (a) => a.kind == VerificationArtifactKind.networkFailures,
        );
        expect(
          utf8.decode((await h.service.readArtifact(console))!),
          contains('save is not a function'),
        );
        expect(
          utf8.decode((await h.service.readArtifact(network))!),
          contains('500'),
        );
        // And the report a person reads has them in it.
        expect(
          File(p.join(run.artifactDirectory, 'report.md')).readAsStringSync(),
          contains('save is not a function'),
        );
      },
    );

    test('a quiet page produces no console file at all', () async {
      await h.service.start(
        target: const VerificationTarget.browser('https://example.com'),
      );
      final finished = await h.service.finish(
        verdict: VerificationVerdict.pass,
      );

      expect(
        finished.artifacts.where(
          (a) => a.kind == VerificationArtifactKind.consoleErrors,
        ),
        isEmpty,
      );
    });

    test('a device run closes with a logcat slice and a UI tree', () async {
      final finished = await h.service
          .start(
            target: const VerificationTarget.device(
              serial: 'FAKE123',
              packageName: 'com.example.app',
            ),
          )
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
        await h.service.start(
          target: const VerificationTarget.device(
            serial: 'FAKE123',
            packageName: 'com.example.app',
          ),
        );
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
          target: const VerificationTarget.browser('https://a.test'),
        );
        await h.service.finish(verdict: VerificationVerdict.pass);
        await h.service.start(
          target: const VerificationTarget.browser('https://b.test'),
        );
        await h.service.finish(verdict: VerificationVerdict.pass);

        expect(h.service.find('run-001')!.target.url, 'https://a.test');
        expect(h.service.find('run-'), isNull);
        expect(h.service.matching('run-'), hasLength(2));
      },
    );

    test('deleting a run removes its files as well as its rows', () async {
      final run = await h.service.start(
        target: const VerificationTarget.browser('https://example.com'),
      );
      await h.service.finish(verdict: VerificationVerdict.pass);
      expect(Directory(run.artifactDirectory).existsSync(), isTrue);

      await h.service.delete(run.id);

      expect(h.service.get(run.id), isNull);
      expect(Directory(run.artifactDirectory).existsSync(), isFalse);
    });

    test('abandoning leaves the run open and takes the sinks off', () async {
      final run = await h.service.start(
        target: const VerificationTarget.browser('https://example.com'),
      );
      await h.service.abandon();

      expect(h.service.activeRun, isNull);
      expect(h.service.get(run.id)!.isOpen, isTrue);
      expect(h.browser.service.actionSink, isNull);
    });
  });
}
