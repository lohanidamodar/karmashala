import 'dart:io';

import 'package:chitragupta/src/app/theme/app_theme.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/features/verification/application/verification_providers.dart';
import 'package:chitragupta/src/features/verification/domain/verification_artifact.dart';
import 'package:chitragupta/src/features/verification/domain/verification_run.dart';
import 'package:chitragupta/src/features/verification/domain/verification_step.dart';
import 'package:chitragupta/src/features/verification/domain/verification_target.dart';
import 'package:chitragupta/src/features/verification/presentation/verification_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'verification_harness.dart';

final _t0 = DateTime.utc(2026, 8, 30, 12);

/// Everything here is arranged **synchronously**.
///
/// `testWidgets` runs its body in a fake-async zone where awaiting real file
/// I/O never completes — `await Directory.create()` inside a widget test hangs
/// the run with no timeout and no error, and `tester.runAsync` did not rescue
/// it either. So the fixtures are written with the DAO (whose SQL is sync) and
/// `writeAsStringSync`, and the service's own behaviour is covered by
/// `verification_service_test.dart`, which is a plain `test()` and can await.
void main() {
  late VerificationHarness h;

  setUp(() => h = VerificationHarness());
  tearDown(() => h.dispose());

  /// Writes a run straight into the database, and its files straight to disk.
  VerificationRun seed({
    required String id,
    required String title,
    VerificationTarget? target,
    VerificationVerdict? verdict,
    String? reason,
    String? sessionId,
    List<VerificationStep> steps = const [],
    Map<String, String> files = const {},
    List<String> missingImages = const [],
  }) {
    final directory = p.join(h.root.path, id);
    Directory(directory).createSync(recursive: true);
    final run = VerificationRun(
      id: id,
      title: title,
      target: target ?? const VerificationTarget.browser('https://example.com'),
      sessionId: sessionId,
      startedAt: _t0,
      finishedAt: verdict == null ? null : _t0.add(const Duration(seconds: 9)),
      verdict: verdict,
      reason: reason,
      artifactDirectory: directory,
    );
    h.dao.insertRun(run);
    for (final step in steps) {
      h.dao.insertStep(id, step);
    }
    files.forEach((name, body) {
      File(p.join(directory, name)).writeAsStringSync(body);
      h.dao.insertArtifact(
        VerificationArtifact(
          id: '$id:$name',
          runId: id,
          kind: name.endsWith('.png')
              ? VerificationArtifactKind.screenshot
              : VerificationArtifactKind.consoleErrors,
          label: name.endsWith('.png') ? 'The page' : '1 console error',
          relativePath: name,
          byteSize: body.length,
          at: _t0,
        ),
      );
    });
    for (final name in missingImages) {
      h.dao.insertArtifact(
        VerificationArtifact(
          id: '$id:$name',
          runId: id,
          kind: VerificationArtifactKind.screenshot,
          label: 'The page when the run finished',
          relativePath: name,
          byteSize: 1234,
          at: _t0,
        ),
      );
    }
    return run;
  }

  VerificationStep step(
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

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(h.db),
          verificationRootProvider.overrideWithValue(h.root),
          // Without this the pane waits on path_provider, which has no
          // platform channel in a widget test.
          verificationRootReadyProvider.overrideWith((ref) async => h.root),
          verificationServiceProvider.overrideWithValue(h.service),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: SizedBox(width: 380, height: 800, child: VerificationPane()),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> tapAndSettle(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('with nothing recorded it says what a run is for', (
    tester,
  ) async {
    await pump(tester);
    expect(find.textContaining('Nothing verified yet'), findsOneWidget);
    expect(find.text('No runs'), findsOneWidget);
  });

  testWidgets('a run is a row with its verdict, target and counts', (
    tester,
  ) async {
    seed(
      id: 'run-001',
      title: 'the settings page saves',
      target: const VerificationTarget.browser('https://example.com/settings'),
      verdict: VerificationVerdict.pass,
      reason: 'the row appeared',
      steps: [step(1, 'Navigated'), step(2, 'Clicked Save')],
    );

    await pump(tester);

    expect(find.text('PASS'), findsOneWidget);
    expect(find.text('the settings page saves'), findsOneWidget);
    expect(find.textContaining('https://example.com/settings'), findsOneWidget);
    expect(find.textContaining('2 steps'), findsOneWidget);
    expect(find.text('1 run'), findsOneWidget);
  });

  testWidgets('a device run names the device and the package', (tester) async {
    seed(
      id: 'run-002',
      title: 'the app still opens',
      target: const VerificationTarget.device(
        serial: 'F6IZLV6LMFT4U4ZT',
        packageName: 'com.example.app',
      ),
      verdict: VerificationVerdict.pass,
    );

    await pump(tester);

    expect(find.textContaining('F6IZLV6LMFT4U4ZT'), findsOneWidget);
    expect(find.textContaining('com.example.app'), findsOneWidget);
  });

  testWidgets('opening a run shows its steps, and back returns to the list', (
    tester,
  ) async {
    seed(
      id: 'run-003',
      title: 'a run worth reading',
      verdict: VerificationVerdict.fail,
      reason: 'the button did nothing',
      steps: [
        step(1, 'Navigated to /settings', kind: VerificationStepKind.navigate),
        step(2, 'checked the header', kind: VerificationStepKind.note),
      ],
    );

    await pump(tester);
    await tapAndSettle(tester, find.text('a run worth reading'));

    expect(find.text('the button did nothing'), findsOneWidget);
    expect(find.textContaining('checked the header'), findsOneWidget);
    expect(find.textContaining('STEPS ('), findsOneWidget);

    await tapAndSettle(tester, find.byTooltip('Back to the runs'));
    expect(find.text('a run worth reading'), findsOneWidget);
    expect(find.text('the button did nothing'), findsNothing);
  });

  testWidgets('a failed step is marked as one, with its reason', (
    tester,
  ) async {
    seed(
      id: 'run-004',
      title: 'a run with a failure',
      verdict: VerificationVerdict.fail,
      steps: [
        step(
          1,
          'Clicked #save',
          ok: false,
          detail: 'a cookie banner covered it',
        ),
      ],
    );

    await pump(tester);
    await tapAndSettle(tester, find.text('a run with a failure'));

    expect(find.text('FAIL'), findsWidgets);
    expect(find.textContaining('Click'), findsOneWidget);
    expect(find.text('a cookie banner covered it'), findsOneWidget);
  });

  testWidgets('a run still recording reads as open, not as a pass', (
    tester,
  ) async {
    seed(id: 'run-005', title: 'still going');

    await pump(tester);

    expect(find.text('OPEN'), findsOneWidget);
    expect(find.textContaining('No reason was recorded'), findsNothing);
  });

  testWidgets('an evidence file expands in place', (tester) async {
    seed(
      id: 'run-006',
      title: 'a noisy page',
      verdict: VerificationVerdict.fail,
      files: {'console.txt': '[error] TypeError: save is not a function'},
    );

    await pump(tester);
    await tapAndSettle(tester, find.text('a noisy page'));

    expect(
      find.textContaining('TypeError: save is not a function'),
      findsNothing,
    );
    await tapAndSettle(tester, find.textContaining('1 console error'));
    expect(
      find.textContaining('TypeError: save is not a function'),
      findsOneWidget,
    );
  });

  testWidgets('a screenshot whose file has gone says so, and does not throw', (
    tester,
  ) async {
    seed(
      id: 'run-007',
      title: 'a run whose files were cleaned up',
      verdict: VerificationVerdict.pass,
      missingImages: ['zz-final.png'],
    );

    await pump(tester);
    await tapAndSettle(tester, find.text('a run whose files were cleaned up'));

    expect(find.textContaining('not on disk any more'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a run with no session says so rather than showing nothing', (
    tester,
  ) async {
    seed(id: 'run-008', title: 'unattached', verdict: VerificationVerdict.pass);

    await pump(tester);
    await tapAndSettle(tester, find.text('unattached'));

    expect(find.text('not attached to one'), findsOneWidget);
  });

  group('formatting', () {
    test('a duration reads as seconds, then as minutes', () {
      expect(formatRunDuration(const Duration(seconds: 9)), '9s');
      expect(formatRunDuration(const Duration(seconds: 65)), '1m 05s');
    });

    test('a run is described by its age, not its timestamp', () {
      final now = DateTime.utc(2026, 8, 30, 12);
      expect(
        formatWhen(now.subtract(const Duration(seconds: 5)), now: now),
        'just now',
      );
      expect(
        formatWhen(now.subtract(const Duration(minutes: 4)), now: now),
        '4m ago',
      );
      expect(
        formatWhen(now.subtract(const Duration(hours: 3)), now: now),
        '3h ago',
      );
      expect(
        formatWhen(now.subtract(const Duration(days: 1)), now: now),
        'yesterday',
      );
      expect(
        formatWhen(now.subtract(const Duration(days: 4)), now: now),
        '4d ago',
      );
    });
  });
}
