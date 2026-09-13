import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala/src/features/git/application/remote_links.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala/src/features/git/presentation/changes_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A clone with no worktrees: the header's picker has nothing to offer and
  // draws nothing, which is what every case below expects to see.
  final noWorktrees = repoWorktreesProvider.overrideWith(
    (ref) async => const <GitWorktree>[],
  );

  Future<void> pump(
    WidgetTester tester, {
    required List<FileChange> files,
    List<GitCommit> commits = const [],
    SessionDelivery? delivery,
    Map<String, FileDiffStat> stats = const {},
  }) {
    return tester.pumpWidget(
      ProviderScope(
        overrides: [
          noWorktrees,
          repositoryChangesProvider.overrideWith((ref) async => files),
          repositoryFileDiffStatsProvider.overrideWith((ref) async => stats),
          recentCommitsProvider.overrideWith((ref) async => commits),
          selectedRepositoryIdProvider.overrideWith(
            () => _FixedRepository(delivery == null ? null : 'r1'),
          ),
          repositoryDeliveryProvider.overrideWith(
            (ref, _) async => delivery ?? SessionDelivery.unknown,
          ),
          fileDiffByPathProvider(
            'lib/main.dart',
          ).overrideWith((ref) async => '@@ -1 +1 @@\n-old line\n+new line\n'),
        ],
        child: const MaterialApp(
          home: Scaffold(body: ChangesView(repositoryName: 'app')),
        ),
      ),
    );
  }

  testWidgets('a row is a name, its folder, its counts and its status', (
    tester,
  ) async {
    await pump(
      tester,
      files: const [
        FileChange(
          path: 'lib/main.dart',
          type: FileChangeType.modified,
          staged: false,
          unstaged: true,
        ),
      ],
      stats: const {'lib/main.dart': FileDiffStat(added: 4, removed: 1)},
    );
    await tester.pumpAndSettle();

    expect(find.text('main.dart'), findsOneWidget);
    expect(find.text('lib'), findsOneWidget);
    // One label, so the pair is read as one phrase rather than two numbers.
    expect(find.text('+4 −1'), findsOneWidget);
    // git's own letter, and the words behind it for anyone who cannot see
    // which colour it is drawn in.
    expect(find.text('M'), findsOneWidget);
    expect(find.byTooltip('modified'), findsOneWidget);

    // The diff is not here any more — reading one is a tab's job.
    expect(find.text('+new line'), findsNothing);
    await tester.tap(find.text('main.dart'));
    await tester.pumpAndSettle();
    expect(find.text('+new line'), findsNothing);
  });

  testWidgets('a file git reported no counts for simply shows none', (
    tester,
  ) async {
    // `git diff --numstat` never sees an untracked file, and `+0 −0` would be
    // a number we were not given.
    await pump(
      tester,
      files: const [
        FileChange(
          path: 'lib/new.dart',
          type: FileChangeType.untracked,
          staged: false,
          unstaged: true,
        ),
      ],
    );
    await tester.pumpAndSettle();

    expect(find.text('new.dart'), findsOneWidget);
    expect(find.text('U'), findsOneWidget);
    expect(find.textContaining('+'), findsNothing);
  });

  testWidgets('the list opens on what a reviewer reads first, and hides none', (
    tester,
  ) async {
    // git lists these alphabetically, which puts the lockfile at the top of
    // every review. Tiered, never filtered — see `review_order.dart`.
    await pump(
      tester,
      files: const [
        FileChange(
          path: 'build/app/outputs/log.txt',
          type: FileChangeType.modified,
          staged: false,
          unstaged: true,
        ),
        FileChange(
          path: 'lib/models/user.g.dart',
          type: FileChangeType.modified,
          staged: false,
          unstaged: true,
        ),
        FileChange(
          path: 'pubspec.lock',
          type: FileChangeType.modified,
          staged: false,
          unstaged: true,
        ),
        FileChange(
          path: 'lib/main.dart',
          type: FileChangeType.modified,
          staged: false,
          unstaged: true,
        ),
      ],
    );
    await tester.pumpAndSettle();

    double top(String path) => tester.getTopLeft(find.text(path)).dy;

    expect(top('main.dart'), lessThan(top('user.g.dart')));
    expect(top('user.g.dart'), lessThan(top('pubspec.lock')));
    expect(top('pubspec.lock'), lessThan(top('log.txt')));
    // Every one of them is still on screen.
    expect(find.byType(ListTile), findsNothing);
    expect(find.text('log.txt'), findsOneWidget);
  });

  testWidgets('shows an empty state when there are no changes', (tester) async {
    await pump(tester, files: const []);
    await tester.pumpAndSettle();
    expect(find.text('No working-tree changes.'), findsOneWidget);
  });

  testWidgets('the header links the branch, the head commit and the PR', (
    tester,
  ) async {
    final opened = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          noWorktrees,
          // No workspace behind this one: the selection is a stub rather than a
          // row, so the checkout it would resolve to is stated instead of read.
          // The picker itself is covered by `worktree_browse_test.dart`.
          selectedCheckoutPathProvider.overrideWithValue(null),
          repositoryChangesProvider.overrideWith((ref) async => const []),
          recentCommitsProvider.overrideWith(
            (ref) async => const [
              GitCommit(
                sha: 'abcdef1234567890',
                author: 'me',
                subject: 'the last commit',
              ),
            ],
          ),
          selectedRepositoryIdProvider.overrideWith(
            () => _FixedRepository('r1'),
          ),
          repositoryDeliveryProvider.overrideWith(
            (ref, _) async => const SessionDelivery(
              branch: 'work',
              hasRemote: true,
              remote: RemoteRepo(host: 'github.com', slug: 'o/r'),
            ),
          ),
          openExternalUrlProvider.overrideWithValue((url) async {
            opened.add(url);
            return true;
          }),
        ],
        child: const MaterialApp(
          home: Scaffold(body: ChangesView(repositoryName: 'app')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('work'), findsOneWidget);
    expect(find.text('abcdef1'), findsOneWidget);

    await tester.tap(find.text('abcdef1'));
    await tester.pumpAndSettle();
    expect(opened, ['https://github.com/o/r/commit/abcdef1234567890']);

    // The panel can be dragged narrow; the header must ellipsise rather than
    // overflow, which would fail this pump on its own.
    tester.view.physicalSize = const Size(250, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpAndSettle();
    expect(find.text('CHANGES'), findsOneWidget);
  });
}

/// A fixed selection, so the header has a repository to describe.
class _FixedRepository extends SelectedRepositoryController {
  _FixedRepository(this._id);
  final String? _id;

  @override
  String? build() => _id;
}
