import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/git/application/review_threads.dart';
import 'package:karmashala/src/features/git/domain/file_change.dart';
import 'package:karmashala/src/features/git/domain/git_commit.dart';
import 'package:karmashala/src/features/git/domain/remote_repo.dart';
import 'package:karmashala/src/features/git/domain/review_thread.dart';
import 'package:karmashala/src/features/github/domain/pull_request_snapshot.dart';
import 'package:karmashala/src/features/git/presentation/changes_view.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/domain/session_delivery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

/// **What one provider moving costs the file list.**
///
/// `ChangesView.build` used to watch six providers in one build: the changes,
/// the selected repository, the selected session, the review threads, the
/// delivery and the commit log. Five of those are drawn by the header alone,
/// and every one of them repainted all six file rows — a git poll landing a new
/// head commit redrew a diff panel that had not changed.
///
/// Counted, never timed, for the reason the other cost tests in this suite
/// give: the suite runs at `--concurrency=4`, so a wall-clock assertion over a
/// few milliseconds is a coin toss, while widget builds are countable exactly.
///
/// What it measures (2026-09-03), against six changed files:
///
/// | change                     | file-row builds before | after |
/// | -------------------------- | ---------------------: | ----: |
/// | a new head commit          |                      6 |     0 |
/// | a pull request appearing   |                      6 |     0 |
/// | a review thread arriving   |                      6 |     0 |
/// | selecting a session        |                      6 |     0 |
/// | the changes themselves     |                      6 |     6 |
///
/// The last row is the control: the list still repaints when the thing it
/// draws moves, so a zero above cannot be bought by drawing nothing.
void main() {
  const paths = [
    'lib/main.dart',
    'lib/src/app.dart',
    'lib/src/router.dart',
    'lib/src/theme.dart',
    'test/app_test.dart',
    'README.md',
  ];

  final files = <FileChange>[
    for (final path in paths)
      FileChange(
        path: path,
        type: FileChangeType.modified,
        staged: false,
        unstaged: true,
      ),
  ];

  const head = GitCommit(
    sha: 'abcdef1234567890',
    author: 'me',
    subject: 'the last commit',
  );

  /// A thread somebody triaged as should-fix, which is the only kind the
  /// header's send button counts.
  AnchoredReviewThread pendingThread(String id) => AnchoredReviewThread(
    ReviewThread(
      id: id,
      repositoryId: 'r1',
      anchor: const ReviewAnchor(
        path: 'lib/main.dart',
        blobSha: 'sha-1',
        startLine: 3,
        endLine: 3,
      ),
      status: ReviewThreadStatus.shouldFix,
      createdAt: testTime,
      updatedAt: testTime,
    ),
    ReviewThreadAttachment.attached,
  );

  /// Everything the panel reads, held where a test can move one of them and
  /// leave the rest exactly as they were.
  late List<FileChange> changes;
  late List<GitCommit> commits;
  late SessionDelivery delivery;
  late ReviewThreadIndex threads;

  setUp(() {
    changes = files;
    commits = const [head];
    delivery = const SessionDelivery(
      branch: 'work',
      hasRemote: true,
      remote: RemoteRepo(host: 'github.com', slug: 'o/r'),
    );
    threads = ReviewThreadIndex.empty;
  });

  Future<ProviderContainer> pump(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        selectedRepositoryIdProvider.overrideWith(_FixedRepository.new),
        repositoryChangesProvider.overrideWith((ref) async => changes),
        recentCommitsProvider.overrideWith((ref) async => commits),
        repositoryDeliveryProvider.overrideWith((ref, _) async => delivery),
        repositoryReviewThreadsProvider.overrideWith((ref) async => threads),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: ChangesView(repositoryName: 'app')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Every row is on screen at the default surface, so "0 builds" below is a
    // claim about rows that exist rather than rows the list never reached.
    expect(find.text('README.md'), findsOneWidget);
    ChangesView.debugFileRowBuildCount = 0;
    return container;
  }

  testWidgets('a new head commit repaints the link and no file row', (
    tester,
  ) async {
    final container = await pump(tester);
    expect(find.text('abcdef1'), findsOneWidget);

    commits = const [
      GitCommit(sha: '9876543210fedcba', author: 'me', subject: 'and another'),
      head,
    ];
    // Re-runs the provider against the list the closure above now returns.
    container.invalidate(recentCommitsProvider);
    await tester.pumpAndSettle();

    expect(find.text('9876543'), findsOneWidget);
    expect(
      ChangesView.debugFileRowBuildCount,
      0,
      reason: 'the file list knows nothing about the commit log',
    );
  });

  testWidgets('a pull request appearing repaints the header and no file row', (
    tester,
  ) async {
    final container = await pump(tester);
    expect(find.text('#41'), findsNothing);

    delivery = const SessionDelivery(
      branch: 'work',
      hasRemote: true,
      remote: RemoteRepo(host: 'github.com', slug: 'o/r'),
      pullRequest: PullRequestSnapshot(
        number: 41,
        state: PullRequestState.open,
        url: 'https://github.com/o/r/pull/41',
        title: 'the work',
      ),
    );
    container.invalidate(repositoryDeliveryProvider);
    await tester.pumpAndSettle();

    expect(find.text('#41'), findsOneWidget);
    expect(
      ChangesView.debugFileRowBuildCount,
      0,
      reason: 'a forge link is header furniture, not a change to any file',
    );
  });

  testWidgets('a review thread arriving repaints the badge and no file row', (
    tester,
  ) async {
    // The writer is not always this process: an agent replying over MCP bumps
    // the revision the index watches, and the panel a human is reading has to
    // notice. It must notice in one badge.
    final container = await pump(tester);
    expect(find.text('1'), findsNothing);

    threads = ReviewThreadIndex([pendingThread('t1')]);
    container.invalidate(repositoryReviewThreadsProvider);
    await tester.pumpAndSettle();

    expect(find.text('1'), findsOneWidget);
    expect(
      ChangesView.debugFileRowBuildCount,
      0,
      reason: 'the badge counts threads; the rows list files',
    );
  });

  testWidgets('selecting a session costs the file list nothing', (
    tester,
  ) async {
    // The selection only decides whether the send button is enabled and what
    // its tooltip says. Switching sessions is the most frequent thing a user
    // does in this app, and it used to repaint every row of every open diff.
    threads = ReviewThreadIndex([pendingThread('t1')]);
    final container = await pump(tester);

    container.read(selectedSessionIdProvider.notifier).select('s1');
    await tester.pumpAndSettle();

    expect(ChangesView.debugFileRowBuildCount, 0);
  });

  testWidgets('...but the changes themselves still repaint every row', (
    tester,
  ) async {
    // The control. Without it every zero above could be bought by a list that
    // stopped listening to anything at all.
    final container = await pump(tester);

    changes = [
      const FileChange(
        path: 'lib/main.dart',
        type: FileChangeType.modified,
        staged: true,
        unstaged: false,
      ),
      ...files.skip(1),
    ];
    container.invalidate(repositoryChangesProvider);
    await tester.pumpAndSettle();

    expect(
      ChangesView.debugFileRowBuildCount,
      files.length,
      reason: 'one build per row, and no repeats',
    );
  });
}

/// A fixed selection, so the header has a repository to describe.
class _FixedRepository extends SelectedRepositoryController {
  @override
  String? build() => 'r1';
}
