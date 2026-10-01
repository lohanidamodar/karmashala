import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala/src/features/git/presentation/changes_view.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';

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

  late FakeDataServer server;

  /// Whether the server says a merge is half done, and whether an abort
  /// brings the tree back.
  void serverSays({bool? mergeHead, bool aborted = true}) {
    server.gitWork.mergesInProgress[Checkout(repo)] = mergeHead;
    server.gitWork.abortRestores = aborted;
  }

  List<String> asked() => server.gitWork.kinds;

  setUp(() async {
    server = FakeDataServer()..environmentRows.upsert(windowsEnv());
  });

  /// [changes] of null is the listing failing — a folder that is not a
  /// repository, a checkout this host cannot reach, a real `fatal:`.
  Future<void> pump(
    WidgetTester tester, {
    List<FileChange>? changes = const [],
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          await server.override(),
          repoWorktreesProvider.overrideWith(
            (ref) async => const <GitWorktree>[],
          ),
          viewedCheckoutProvider.overrideWithValue(repo),
          repositoryChangesProvider.overrideWith(
            (ref) async =>
                changes ?? (throw StateError('fatal: not a git repository')),
          ),
          recentCommitsProvider.overrideWith((ref) async => const []),
          // The pane's other reads are not what these cases count — the
          // commit box's "is this a repository" among them (5d6f40eea).
          repositoryFileDiffStatsProvider.overrideWith((ref) async => const {}),
          checkoutGitPresenceProvider.overrideWith(
            (ref, _) async => GitPresence.repository,
          ),
          workingTreeStatusProvider.overrideWith(
            (ref) async => const WorkingTreeStatus(branch: 'work'),
          ),
          repositoryDeliveryProvider.overrideWith(
            (ref, _) async => SessionDelivery.unknown,
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: ChangesView(repositoryName: 'app')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('it appears only when there is something to abort', () {
    testWidgets('a dirty tree that is not a merge does not offer to undo one', (
      tester,
    ) async {
      serverSays(mergeHead: false);
      await pump(tester, changes: [ordinary]);
      expect(find.byTooltip('Abort merge'), findsNothing);
      // One question, answered from the server's stat of `MERGE_HEAD`.
      expect(asked(), [GitMergeInProgress.name]);
    });

    testWidgets('a clean tree is not a merge, and costs no read to know', (
      tester,
    ) async {
      // A merge that stopped left its work in the index and resolving one with
      // `git add` leaves it staged, so an empty listing settles it.
      serverSays(mergeHead: true);
      await pump(tester);
      expect(find.byTooltip('Abort merge'), findsNothing);
      expect(asked(), isEmpty);
    });

    testWidgets('a conflicted row is a merge, and costs no file read at all', (
      tester,
    ) async {
      serverSays(mergeHead: false);
      await pump(tester, changes: [conflicted]);
      expect(find.byTooltip('Abort merge'), findsOneWidget);
      expect(
        asked(),
        isEmpty,
        reason: 'the listing already answered; nothing needs asking',
      );
    });

    testWidgets('every conflict resolved still leaves a merge to abort', (
      tester,
    ) async {
      // The state the listing cannot see: `git add` on every conflict clears
      // the `u` records, and `.git/MERGE_HEAD` is still there because nothing
      // has been committed.
      serverSays(mergeHead: true);
      await pump(tester, changes: [ordinary]);
      expect(find.byTooltip('Abort merge'), findsOneWidget);
    });

    testWidgets('a listing git could not produce hides it, and arms no retry', (
      tester,
    ) async {
      // The pane beside this already shows git's own words for the trouble.
      // What this must not do is inherit the listing's retry: that backoff
      // timer outlives the pane, and the framework fails the test for it.
      await pump(tester, changes: null);
      expect(find.byTooltip('Abort merge'), findsNothing);
    });

    testWidgets(
      'a filesystem this host cannot read hides it rather than guessing',
      (tester) async {
        // The server answers null for a filesystem it cannot see. A button
        // that destroys work appears on evidence, never on a shrug.
        serverSays(mergeHead: null);
        await pump(tester, changes: [ordinary]);
        expect(find.byTooltip('Abort merge'), findsNothing);
      },
    );
  });

  testWidgets(
    'the confirm says what is discarded, and cancelling runs nothing',
    (tester) async {
      await pump(tester, changes: [conflicted]);

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
      expect(asked(), isEmpty);
    },
  );

  testWidgets('confirming asks the server to abort and says the tree is back', (
    tester,
  ) async {
    await pump(tester, changes: [conflicted]);

    await tester.tap(find.byTooltip('Abort merge'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Abort merge').last);
    await tester.pumpAndSettle();

    expect(asked(), [GitAbortMerge.name]);
    expect(find.textContaining('Merge aborted'), findsOneWidget);
  });

  testWidgets(
    'an abort with no merge to undo says so rather than claiming one',
    (tester) async {
      // The reading was taken a moment ago and is not a promise about what git
      // will find, so the outcome still states which of the two happened.
      serverSays(aborted: false);
      await pump(tester, changes: [conflicted]);

      await tester.tap(find.byTooltip('Abort merge'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Abort merge').last);
      await tester.pumpAndSettle();

      expect(find.textContaining('no merge'), findsOneWidget);
      expect(find.textContaining('Merge aborted'), findsNothing);
    },
  );

  testWidgets('a conflicted file is rendered as one, and says which kind', (
    tester,
  ) async {
    // It used to draw as "changed (unrecognised git status)" — git's shrug
    // borrowed for a status git names exactly.
    await pump(tester, changes: [conflicted]);
    expect(find.byTooltip('conflicted — both modified'), findsOneWidget);
  });
}
