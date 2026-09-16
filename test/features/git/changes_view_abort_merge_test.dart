import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/git/application/changes_service.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala/src/features/git/presentation/changes_view.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// A `.git` directory with, or without, the file `git merge` leaves behind.
///
/// Counted, because the whole argument for reading it is that it is not a
/// process and does not run on a timer.
class _GitDirWith implements GitFiles {
  _GitDirWith({required this.mergeHead});

  final bool mergeHead;
  int stats = 0;

  @override
  Future<PathEntry> typeOf(String path) async {
    stats++;
    if (path.endsWith('MERGE_HEAD')) {
      return mergeHead ? PathEntry.file : PathEntry.none;
    }
    return path.endsWith('.git') ? PathEntry.directory : PathEntry.none;
  }

  @override
  Future<String?> readString(String path) async => null;

  @override
  Future<bool> exists(String path) async => false;

  @override
  Future<void> createDirectory(String path) async {}

  @override
  Future<void> writeString(String path, String contents) async {}
}

/// `git merge --abort`, reachable by hand — **and only when there is a merge**.
///
/// It had exactly one caller, the delivery pipeline's failure path, so a merge
/// an agent left half-done could only be undone by asking a model to run the
/// command. Merge and push stay prompts; this one is the app's because there is
/// nothing in it to decide.
///
/// What it must not be is permanent. A button that discards work, sitting in
/// the header of a clean tree, is an offer to throw away something that is not
/// there — so it appears on evidence: a conflicted row in the listing the panel
/// is already showing, or the `.git/MERGE_HEAD` that survives once every
/// conflict has been resolved and nothing has been committed.
void main() {
  const repo = EnvironmentPath(environmentId: 'windows', path: r'C:\app');

  const conflicted = FileChange(
    path: 'lib/a.dart',
    type: FileChangeType.conflicted,
    conflict: MergeConflict.bothModified,
    staged: true,
    unstaged: true,
  );

  const ordinary = FileChange(
    path: 'lib/b.dart',
    type: FileChangeType.modified,
    staged: false,
    unstaged: true,
  );

  late AppDatabase db;
  late FakeCommandRunner runner;

  /// Answers `merge --abort` with [aborted] and every read with nothing.
  ChangesService serviceThatAborts({
    required bool aborted,
    GitFiles files = noGitFiles,
  }) {
    runner = FakeCommandRunner(
      responder: (req) => req.arguments.contains('--abort')
          ? CommandResult(
              exitCode: aborted ? 0 : 128,
              stdout: '',
              stderr: aborted ? '' : 'fatal: There is no merge to abort',
            )
          : const CommandResult(exitCode: 0, stdout: '', stderr: ''),
    );
    return ChangesService(
      runnerFactory: FakeCommandRunnerFactory(fallback: runner),
      environmentDao: ExecutionEnvironmentDao(db),
      files: files,
    );
  }

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
  });
  tearDown(() => db.close());

  /// [changes] of null is the listing failing — a folder that is not a
  /// repository, a checkout this host cannot reach, a real `fatal:`.
  Future<void> pump(
    WidgetTester tester,
    ChangesService service, {
    List<FileChange>? changes = const [],
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          repoWorktreesProvider.overrideWith((ref) async => const <GitWorktree>[]),
          viewedCheckoutProvider.overrideWithValue(repo),
          repositoryChangesProvider.overrideWith(
            (ref) async =>
                changes ?? (throw StateError('fatal: not a git repository')),
          ),
          recentCommitsProvider.overrideWith((ref) async => const []),
          repositoryDeliveryProvider.overrideWith(
            (ref, _) async => SessionDelivery.unknown,
          ),
          changesServiceProvider.overrideWithValue(service),
        ],
        child: const MaterialApp(
          home: Scaffold(body: ChangesView(repositoryName: 'app')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('it appears only when there is something to abort', () {
    testWidgets('a dirty tree that is not a merge does not offer to undo one',
        (tester) async {
      final files = _GitDirWith(mergeHead: false);
      await pump(
        tester,
        serviceThatAborts(aborted: true, files: files),
        changes: [ordinary],
      );
      expect(find.byTooltip('Abort merge'), findsNothing);
      // Two stats and no process: `MERGE_HEAD`, then `.git` itself to tell an
      // absent file from a filesystem that did not answer.
      expect(files.stats, 2);
      expect(runner.requests, isEmpty);
    });

    testWidgets('a clean tree is not a merge, and costs no read to know',
        (tester) async {
      // A merge that stopped left its work in the index and resolving one with
      // `git add` leaves it staged, so an empty listing settles it.
      final files = _GitDirWith(mergeHead: true);
      await pump(tester, serviceThatAborts(aborted: true, files: files));
      expect(find.byTooltip('Abort merge'), findsNothing);
      expect(files.stats, 0);
    });

    testWidgets('a conflicted row is a merge, and costs no file read at all',
        (tester) async {
      final files = _GitDirWith(mergeHead: false);
      await pump(
        tester,
        serviceThatAborts(aborted: true, files: files),
        changes: [conflicted],
      );
      expect(find.byTooltip('Abort merge'), findsOneWidget);
      expect(
        files.stats,
        0,
        reason: 'the listing already answered; nothing needs to touch a disk',
      );
    });

    testWidgets('every conflict resolved still leaves a merge to abort',
        (tester) async {
      // The state the listing cannot see: `git add` on every conflict clears
      // the `u` records, and `.git/MERGE_HEAD` is still there because nothing
      // has been committed.
      final files = _GitDirWith(mergeHead: true);
      await pump(
        tester,
        serviceThatAborts(aborted: true, files: files),
        changes: [ordinary],
      );
      expect(find.byTooltip('Abort merge'), findsOneWidget);
    });

    testWidgets('a listing git could not produce hides it, and arms no retry',
        (tester) async {
      // The pane beside this already shows git's own words for the trouble.
      // What this must not do is inherit the listing's retry: that backoff
      // timer outlives the pane, and the framework fails the test for it.
      await pump(
        tester,
        serviceThatAborts(aborted: true),
        changes: null,
      );
      expect(find.byTooltip('Abort merge'), findsNothing);
    });

    testWidgets('a filesystem this host cannot read hides it rather than guessing',
        (tester) async {
      // `noGitFiles` answers `PathEntry.none` for everything, which is what a
      // dead share and an absent `.git` both look like. A button that destroys
      // work appears on evidence, never on a shrug.
      await pump(
        tester,
        serviceThatAborts(aborted: true),
        changes: [ordinary],
      );
      expect(find.byTooltip('Abort merge'), findsNothing);
    });
  });

  testWidgets('the confirm says what is discarded, and cancelling runs nothing',
      (tester) async {
    final service = serviceThatAborts(aborted: true);
    await pump(tester, service, changes: [conflicted]);

    await tester.tap(find.byTooltip('Abort merge'));
    await tester.pumpAndSettle();

    expect(find.text('Abort the merge in progress?'), findsOneWidget);
    expect(
      find.textContaining('conflict resolution'),
      findsOneWidget,
      reason: 'the sentence must say what pressing it throws away',
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(runner.requests, isEmpty);
  });

  testWidgets('confirming runs git merge --abort and says the tree is back',
      (tester) async {
    await pump(
      tester,
      serviceThatAborts(aborted: true),
      changes: [conflicted],
    );

    await tester.tap(find.byTooltip('Abort merge'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Abort merge').last);
    await tester.pumpAndSettle();

    expect(runner.requests.single.arguments, ['-C', r'C:\app', 'merge', '--abort']);
    expect(find.textContaining('Merge aborted'), findsOneWidget);
  });

  testWidgets('an abort with no merge to undo says so rather than claiming one',
      (tester) async {
    // The reading was taken a moment ago and is not a promise about what git
    // will find, so the outcome still states which of the two happened.
    await pump(
      tester,
      serviceThatAborts(aborted: false),
      changes: [conflicted],
    );

    await tester.tap(find.byTooltip('Abort merge'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Abort merge').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('no merge'), findsOneWidget);
    expect(find.textContaining('Merge aborted'), findsNothing);
  });

  testWidgets('a conflicted file is rendered as one, and says which kind',
      (tester) async {
    // It used to draw as "changed (unrecognised git status)" — git's shrug
    // borrowed for a status git names exactly.
    await pump(
      tester,
      serviceThatAborts(aborted: true),
      changes: [conflicted],
    );
    expect(find.byTooltip('conflicted — both modified'), findsOneWidget);
  });
}
