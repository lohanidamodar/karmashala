/// Staging, discarding and committing from the Changes pane, down to the
/// request each button sends the server. What git each request runs is the
/// server's, and proved there (`server/test/git/`, `GitService`'s own tests).
library;

import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/git/presentation/changes_view.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/git.dart';

import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';

void main() {
  const checkout = EnvironmentPath(environmentId: 'windows', path: r'C:\app');
  late FakeDataServer server;
  late DataClient client;

  /// Every write the pane asked the server for, in order.
  List<CheckoutRequest<Object?>> ran() => [
    for (final request in server.gitWork.asked)
      if (request is CheckoutRequest<Object?> &&
          request.checkout.directory == checkout &&
          const {
            GitStage.name,
            GitUnstage.name,
            GitDiscard.name,
            GitCommitStaged.name,
            GitFetch.name,
            GitPull.name,
            GitPush.name,
          }.contains(request.kind))
        request,
  ];

  setUp(() async {
    server = FakeDataServer()..environmentRows.upsert(windowsEnv());
    client = await server.connect();
  });

  Future<void> pump(
    WidgetTester tester, {
    required List<FileChange> files,
    WorkingTreeStatus status = const WorkingTreeStatus(
      branch: 'work',
      upstream: 'origin/work',
      aheadOfUpstream: 0,
      behindUpstream: 0,
    ),
  }) async {
    await tester.binding.setSurfaceSize(const Size(500, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dataClientProvider.overrideWithValue(client),
          repoWorktreesProvider.overrideWith((ref) async => const []),
          repositoryChangesProvider.overrideWith((ref) async => files),
          repositoryFileDiffStatsProvider.overrideWith((ref) async => const {}),
          recentCommitsProvider.overrideWith((ref) async => const []),
          workingTreeStatusProvider.overrideWith((ref) async => status),
          viewedCheckoutProvider.overrideWithValue(checkout),
        ],
        child: const MaterialApp(
          home: Scaffold(body: ChangesView(repositoryName: 'app')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  const modified = FileChange(
    path: 'lib/main.dart',
    type: FileChangeType.modified,
    staged: false,
    unstaged: true,
  );
  const stagedAdd = FileChange(
    path: 'lib/new.dart',
    type: FileChangeType.added,
    staged: true,
    unstaged: false,
  );
  const untracked = FileChange(
    path: 'scratch.txt',
    type: FileChangeType.untracked,
    staged: false,
    unstaged: true,
  );

  testWidgets('what is going into the commit is listed apart from what is '
      'not', (tester) async {
    await pump(tester, files: const [modified, stagedAdd]);

    expect(find.text('STAGED CHANGES  1'), findsOneWidget);
    // Not "Changes": the panel sits under the Changes tab (8e59e76f6).
    expect(find.text('UNSTAGED CHANGES  1'), findsOneWidget);
    expect(find.text('main.dart'), findsOneWidget);
    expect(find.text('new.dart'), findsOneWidget);
  });

  testWidgets('staging one file adds that path and nothing else', (
    tester,
  ) async {
    await pump(tester, files: const [modified]);

    await tester.tap(find.byTooltip('Stage').first);
    await tester.pumpAndSettle();

    expect((ran().single as GitStage).paths, ['lib/main.dart']);
  });

  testWidgets('unstaging restores the index, leaving the file alone', (
    tester,
  ) async {
    await pump(tester, files: const [stagedAdd]);

    await tester.tap(find.byTooltip('Unstage').first);
    await tester.pumpAndSettle();

    expect((ran().single as GitUnstage).paths, ['lib/new.dart']);
  });

  testWidgets('discard asks first, and says an untracked file is deleted', (
    tester,
  ) async {
    await pump(tester, files: const [untracked]);

    await tester.tap(find.byTooltip('Discard changes').first);
    await tester.pumpAndSettle();

    expect(find.textContaining('discarding deletes them'), findsOneWidget);
    expect(ran(), isEmpty, reason: 'nothing runs while the question is up');

    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Discard'),
      ),
    );
    await tester.pumpAndSettle();

    // An untracked file is deleted, not rewound.
    final discard = ran().single as GitDiscard;
    expect(discard.untracked, ['scratch.txt']);
    expect(discard.tracked, isEmpty);
  });

  testWidgets('a tracked discard rewinds the index and the working tree', (
    tester,
  ) async {
    await pump(tester, files: const [modified]);

    await tester.tap(find.byTooltip('Discard changes').first);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Discard'),
      ),
    );
    await tester.pumpAndSettle();

    final discard = ran().single as GitDiscard;
    expect(discard.tracked, ['lib/main.dart']);
    expect(discard.untracked, isEmpty);
  });

  testWidgets('with something staged, Commit commits what is staged', (
    tester,
  ) async {
    await pump(tester, files: const [stagedAdd, modified]);

    await tester.enterText(find.byType(TextField), 'a real message');
    await tester.tap(find.widgetWithText(FilledButton, 'Commit'));
    await tester.pumpAndSettle();

    final commit = ran().single as GitCommitStaged;
    expect(commit.message, 'a real message');
    expect(commit.all, isFalse);
  });

  testWidgets('with nothing staged, the button says so and stages first', (
    tester,
  ) async {
    await pump(tester, files: const [modified]);

    expect(find.widgetWithText(FilledButton, 'Commit all'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'everything');
    await tester.tap(find.widgetWithText(FilledButton, 'Commit all'));
    await tester.pumpAndSettle();

    final commit = ran().single as GitCommitStaged;
    expect(commit.message, 'everything');
    expect(commit.all, isTrue);
  });

  testWidgets('an empty message is refused before git is asked', (
    tester,
  ) async {
    await pump(tester, files: const [stagedAdd]);

    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.widgetWithText(FilledButton, 'Commit'));
    await tester.pumpAndSettle();

    expect(find.textContaining('needs a message'), findsOneWidget);
    expect(ran(), isEmpty);
  });

  testWidgets('what git refused is what the pane says', (tester) async {
    server.gitWork.refusals[GitPush.name] = const DataRefused(
      DataRefusalCode.failed,
      'git push failed: error: failed to push some refs to origin',
    );
    await pump(tester, files: const [modified]);

    await tester.tap(find.byTooltip('Push'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('failed to push some refs'),
      findsOneWidget,
      reason: "git's own sentence, not an exit code",
    );
  });

  testWidgets('a branch with no upstream is published, not pushed', (
    tester,
  ) async {
    await pump(
      tester,
      files: const [],
      status: const WorkingTreeStatus(branch: 'work'),
    );

    expect(find.byTooltip('Push'), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, 'Publish'));
    await tester.pumpAndSettle();

    final push = ran().single as GitPush;
    expect((push.remote, push.branch), ('origin', 'work'));
  });

  /// A push is scanned for secrets at the server; the pane says how it went.
  group('the secret scan before a push', () {
    testWidgets('a finding stops the push, and says where', (tester) async {
      server.gitWork.refusals[GitPush.name] = const DataRefused.invalid(
        'Not pushed: gitleaks found a possible secret in commits no remote '
        'has yet — lib/env.dart:3 (github-pat, f43e2ea).',
      );
      await pump(tester, files: const [modified]);

      await tester.tap(find.byTooltip('Push'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Not pushed'), findsOneWidget);
      expect(find.textContaining('lib/env.dart:3'), findsOneWidget);
    });

    testWidgets('without gitleaks it pushes, and says it did not scan', (
      tester,
    ) async {
      server.gitWork.pushNote =
          'Not scanned for secrets: gitleaks is not installed.';
      await pump(tester, files: const [modified]);

      await tester.tap(find.byTooltip('Push'));
      await tester.pumpAndSettle();

      final push = ran().single as GitPush;
      expect((push.remote, push.branch), (null, null));
      expect(find.textContaining('gitleaks is not installed'), findsOneWidget);
    });

    testWidgets('a clean scan pushes and says so', (tester) async {
      await pump(tester, files: const [modified]);

      await tester.tap(find.byTooltip('Push'));
      await tester.pumpAndSettle();

      expect(ran().single, isA<GitPush>());
      expect(find.textContaining('found no secrets'), findsOneWidget);
    });
  });

  testWidgets('how far the branch is from its upstream is on the row', (
    tester,
  ) async {
    await pump(
      tester,
      files: const [],
      status: const WorkingTreeStatus(
        branch: 'work',
        upstream: 'origin/work',
        aheadOfUpstream: 2,
        behindUpstream: 3,
      ),
    );

    expect(find.text('↓3 ↑2'), findsOneWidget);
    await tester.tap(find.byTooltip('Pull 3'));
    await tester.pumpAndSettle();

    final pull = ran().single as GitPull;
    expect((pull.rebase, pull.merge), (false, false));
  });
}
