import 'package:chitragupta/src/features/git/application/changes_providers.dart';
import 'package:chitragupta/src/features/git/domain/file_change.dart';
import 'package:chitragupta/src/features/git/domain/git_commit.dart';
import 'package:chitragupta/src/features/git/domain/remote_repo.dart';
import 'package:chitragupta/src/features/git/application/remote_links.dart';
import 'package:chitragupta/src/features/sessions/application/delivery_providers.dart';
import 'package:chitragupta/src/features/sessions/domain/session_delivery.dart';
import 'package:chitragupta/src/features/git/presentation/changes_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required List<FileChange> files,
    List<GitCommit> commits = const [],
    SessionDelivery? delivery,
  }) {
    return tester.pumpWidget(
      ProviderScope(
        overrides: [
          repositoryChangesProvider.overrideWith((ref) async => files),
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

  testWidgets('lists changed files and expands one to show its diff inline', (
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
    );
    await tester.pumpAndSettle();

    // Collapsed by default: the file is listed, the diff is not shown yet.
    expect(find.text('lib/main.dart'), findsOneWidget);
    expect(find.text('+new line'), findsNothing);

    // Expanding the file reveals its diff inline.
    await tester.tap(find.text('lib/main.dart'));
    await tester.pumpAndSettle();

    expect(find.text('+new line'), findsOneWidget);
    expect(find.text('-old line'), findsOneWidget);
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
  });
}

/// A fixed selection, so the header has a repository to describe.
class _FixedRepository extends SelectedRepositoryController {
  _FixedRepository(this._id);
  final String? _id;

  @override
  String? build() => _id;
}
