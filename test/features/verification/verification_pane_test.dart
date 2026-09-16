import 'dart:async';
import 'dart:io';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/verification/application/evidence_reader.dart';
import 'package:karmashala/src/features/verification/application/verification_providers.dart';
import 'package:karmashala/src/features/verification/domain/verdict_attribution.dart';
import 'package:karmashala/src/features/verification/domain/verification_artifact.dart';
import 'package:karmashala/src/features/verification/domain/verification_run.dart';
import 'package:karmashala/src/features/verification/domain/verification_step.dart';
import 'package:karmashala/src/features/verification/domain/verification_target.dart';
import 'package:karmashala/src/features/verification/presentation/verification_pane.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_signals.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
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
///
/// That constraint is also why the pane reads evidence through
/// [VerificationEvidenceReader] rather than through bare `dart:io`. The pane
/// used to `existsSync()` beside every screenshot and `readAsStringSync()` a
/// whole artifact on the UI thread; moving both off the frame needed a seam
/// this file could override, and [_SyncEvidenceReader] below is that override —
/// the same files, off the same disk, on a future the fake clock can settle.
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
    String? producedBySessionId,
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
      producedBySessionId: producedBySessionId,
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

  /// The pane as the shell mounts it, in whichever theme is asked for.
  Widget pane({
    required ThemeData theme,
    VerificationEvidenceReader reader = const _SyncEvidenceReader(),
    Widget? home,
  }) => ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(h.db),
      verificationRootProvider.overrideWithValue(h.root),
      verificationEvidenceReaderProvider.overrideWithValue(reader),
      verificationRootReadyProvider.overrideWith((ref) async => h.root),
      verificationServiceProvider.overrideWithValue(h.service),
      verificationChangesProvider.overrideWithValue(h.changes),
    ],
    child: MaterialApp(
      theme: theme,
      home: home ?? const Scaffold(body: VerificationPane()),
    ),
  );

  Future<void> pump(
    WidgetTester tester, {
    VerificationEvidenceReader reader = const _SyncEvidenceReader(),
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(h.db),
          verificationRootProvider.overrideWithValue(h.root),
          verificationEvidenceReaderProvider.overrideWithValue(reader),
          // Without this the pane waits on path_provider, which has no
          // platform channel in a widget test.
          verificationRootReadyProvider.overrideWith((ref) async => h.root),
          verificationServiceProvider.overrideWithValue(h.service),
          // The same signal the harness's service publishes into, so the pane
          // follows *that* service rather than watching a stream nothing fires.
          verificationChangesProvider.overrideWithValue(h.changes),
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

  testWidgets('a renamed session is renamed in the run it verified', (
    tester,
  ) async {
    ExecutionEnvironmentDao(h.db).upsert(windowsEnv());
    ProjectDao(h.db).insert(project());
    RepositoryDao(h.db).insert(repository());
    AgentInstallationDao(h.db).insert(agentInstallation());
    SessionDao(h.db)
      ..insert(session(id: 's-1', title: 'Before the rename'))
      ..insert(session(id: 's-2', title: 'The verifier'));
    seed(
      id: 'run-rename',
      title: 'a run about a session',
      verdict: VerificationVerdict.pass,
      sessionId: 's-1',
      producedBySessionId: 's-2',
    );
    await pump(tester);
    await tapAndSettle(tester, find.text('a run about a session'));
    expect(find.text('Before the rename'), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(VerificationPane)),
    );
    SessionDao(h.db)
      ..updateTitle('s-1', 'After the rename')
      ..updateTitle('s-2', 'The renamed verifier');
    container
        .read(sessionsRevisionProvider.notifier)
        .changed(const SessionChange.renamed('s-1'));
    container
        .read(sessionsRevisionProvider.notifier)
        .changed(const SessionChange.renamed('s-2'));
    await tester.pump();

    expect(find.text('After the rename'), findsOneWidget);
    expect(find.textContaining('The renamed verifier'), findsOneWidget);
  });

  testWidgets('deleting a run asks, with a destructive confirm', (
    tester,
  ) async {
    seed(id: 'run-del', title: 'a run to delete');
    await pump(tester);
    await tapAndSettle(tester, find.text('a run to delete'));
    await tapAndSettle(tester, find.byTooltip('Delete this run'));
    await tester.pumpAndSettle();

    expect(find.text('Delete this run?'), findsOneWidget);
    expect(find.widgetWithText(DestructiveButton, 'Delete'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(h.dao.getRun('run-del'), isNotNull);
  });

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
    // The same glyph a fan-out candidate and a session mark draw for a fail.
    expect(find.byIcon(AppIcons.xCircle), findsWidgets);
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

  testWidgets('an evidence file is read off the frame, not during a build', (
    tester,
  ) async {
    seed(
      id: 'run-006b',
      title: 'a slow page',
      verdict: VerificationVerdict.fail,
      files: {'console.txt': '[error] TypeError: save is not a function'},
    );
    final reader = _ManualEvidenceReader();

    await pump(tester, reader: reader);
    await tapAndSettle(tester, find.text('a slow page'));
    expect(
      reader.pending,
      isEmpty,
      reason: 'listing a run must not read the evidence in it',
    );

    await tester.tap(find.textContaining('1 console error'));
    await tester.pump();

    // The tile is open and the file has *not* been read: the old version
    // answered `readAsStringSync()` inside the tap, which is the whole file on
    // the UI thread before this frame could be built.
    expect(find.textContaining('Reading console.txt'), findsOneWidget);
    expect(reader.pending, hasLength(1));

    reader.pending.single.complete('[error] TypeError: save is not a function');
    await tester.pumpAndSettle();

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

  /// **The white panel was the crash, not a colour.**
  ///
  /// In a release build a widget that throws while building is replaced by
  /// Flutter's default `ErrorWidget`, which paints `Color(0xF0C0C0C0)` — near
  /// white — with its message behind an `assert`. Against the dark theme that
  /// is exactly what "the verification pane is showing white" was: the pane's
  /// own `ref.watch(verificationRunsProvider)` was throwing `ProviderException`
  /// (see `verification_root_ordering_test.dart` for why). Nothing in this
  /// feature draws an unthemed colour at all.
  ///
  /// These pin the other half of that sentence: with the throw gone the pane
  /// draws real lettering in the dark, and it does so at every window size.
  group('in the dark', () {
    Future<void> pumpDark(WidgetTester tester) async {
      await tester.pumpWidget(pane(theme: AppTheme.dark()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('the empty state is lettering, not a blank rectangle', (
      tester,
    ) async {
      await pumpDark(tester);

      expect(tester.takeException(), isNull);
      expect(find.textContaining('Nothing verified yet'), findsOneWidget);
    });

    testWidgets('a run, its verdict and its evidence all draw', (tester) async {
      seed(
        id: 'run-dark',
        title: 'a run read at night',
        verdict: VerificationVerdict.fail,
        reason: 'the button did nothing',
        sessionId: 's-1',
        producedBySessionId: 's-2',
        steps: [step(1, 'Clicked #save', ok: false, detail: 'covered')],
        files: {'console.txt': '[error] boom'},
      );

      await pumpDark(tester);
      await tapAndSettle(tester, find.text('a run read at night'));

      expect(tester.takeException(), isNull);
      expect(find.text('the button did nothing'), findsOneWidget);
      expect(find.text('FAIL'), findsWidgets);
      expect(find.text('covered'), findsOneWidget);
    });

    testWidgets('and the pane survives the window matrix', (tester) async {
      seed(
        id: 'run-matrix',
        title: 'a run at every window size',
        verdict: VerificationVerdict.pass,
        steps: [step(1, 'Navigated'), step(2, 'Clicked Save')],
      );

      await expectSurvivesWindowMatrix(
        tester,
        build: () => pane(theme: AppTheme.dark()),
        because: "the runs list is the panel's narrowest column",
      );
    });

    testWidgets('and in a 240px side panel at the minimum window', (
      tester,
    ) async {
      seed(
        id: 'run-side',
        title: 'a run read in the side panel',
        verdict: VerificationVerdict.inconclusive,
        reason: 'the page never finished loading',
        steps: [step(1, 'Navigated'), step(2, 'Clicked Save', ok: false)],
      );

      await expectSurvivesWindowMatrix(
        tester,
        build: () => pane(
          theme: AppTheme.dark(),
          // Window height less title bar 30, status bar 22, panel header 30.
          home: Scaffold(
            body: LayoutBuilder(
              builder: (context, c) => Align(
                alignment: Alignment.topRight,
                child: SizedBox(
                  width: 240,
                  height: c.maxHeight - 82,
                  child: const Material(child: VerificationPane()),
                ),
              ),
            ),
          ),
        ),
        because: 'the pane is mounted in the side panel, not the whole window',
      );
    });
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

  group('the pane says who produced the verdict', () {
    testWidgets('a self-graded run is labelled as one, not as a clean pass', (
      tester,
    ) async {
      seed(
        id: 'run-self',
        title: 'The author checked itself',
        verdict: VerificationVerdict.pass,
        sessionId: 's-1',
        producedBySessionId: 's-1',
      );
      await pump(tester);

      // Visible on the row, before anything is opened.
      expect(find.text('self'), findsOneWidget);
      await tapAndSettle(tester, find.text('The author checked itself'));
      expect(
        find.textContaining(VerdictAttribution.author.label),
        findsWidgets,
      );
    });

    testWidgets('a run graded by another session reads as independent', (
      tester,
    ) async {
      seed(
        id: 'run-indep',
        title: 'Somebody else checked it',
        verdict: VerificationVerdict.pass,
        sessionId: 's-1',
        producedBySessionId: 's-2',
      );
      await pump(tester);

      expect(find.text('independent'), findsOneWidget);
      expect(find.text('self'), findsNothing);
    });

    testWidgets('a run from before attribution says nobody recorded it', (
      tester,
    ) async {
      seed(
        id: 'run-legacy',
        title: 'An old run',
        verdict: VerificationVerdict.pass,
        sessionId: 's-1',
      );
      await pump(tester);

      expect(find.text('unattributed'), findsOneWidget);
      await tapAndSettle(tester, find.text('An old run'));
      // Not "the author", not "independent" — the gap itself.
      expect(find.textContaining('nobody said who graded'), findsOneWidget);
    });
  });
}

/// The real reader's answers, reached synchronously.
///
/// Not a fake of the *behaviour* — it hits the same files the fixtures wrote —
/// only of the wait, which this zone cannot perform. See the note at the top.
class _SyncEvidenceReader implements VerificationEvidenceReader {
  const _SyncEvidenceReader();

  @override
  Future<bool> exists(String path) => Future.value(File(path).existsSync());

  @override
  Future<String?> read(String path) {
    final file = File(path);
    return Future.value(
      file.existsSync() ? file.readAsStringSync() : null,
    );
  }
}

/// A reader nothing answers until the test says so, for proving that a read
/// happens *after* the frame rather than inside it.
class _ManualEvidenceReader implements VerificationEvidenceReader {
  final List<Completer<String?>> pending = [];

  @override
  Future<bool> exists(String path) => Future.value(true);

  @override
  Future<String?> read(String path) {
    final completer = Completer<String?>();
    pending.add(completer);
    return completer.future;
  }
}
