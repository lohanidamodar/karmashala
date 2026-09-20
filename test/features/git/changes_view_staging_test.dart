/// Staging, discarding and committing from the Changes pane, down to the git
/// each button runs. The service is real over a fake runner, so a case that
/// passes has proved the argv — the difference between `restore --staged` and
/// `reset`, or between rewinding a file and deleting one, is the whole point.
library;

import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/git/application/changes_service.dart';
import 'package:karmashala/src/features/git/presentation/changes_view.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_store/database.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';

void main() {
  const checkout = EnvironmentPath(environmentId: 'windows', path: r'C:\app');
  late AppDatabase db;
  late FakeCommandRunner runner;

  /// Every git command the pane ran, as argv after `-C <path>`.
  List<List<String>> ran() => [
    for (final request in runner.requests) request.arguments.sublist(2),
  ];

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    runner = FakeCommandRunner();
  });
  tearDown(() => db.close());

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
          databaseProvider.overrideWithValue(db),
          repoWorktreesProvider.overrideWith((ref) async => const []),
          repositoryChangesProvider.overrideWith((ref) async => files),
          repositoryFileDiffStatsProvider.overrideWith((ref) async => const {}),
          recentCommitsProvider.overrideWith((ref) async => const []),
          workingTreeStatusProvider.overrideWith((ref) async => status),
          viewedCheckoutProvider.overrideWithValue(checkout),
          changesServiceProvider.overrideWithValue(
            ChangesService(
              runnerFactory: FakeCommandRunnerFactory(fallback: runner),
              environmentDao: ExecutionEnvironmentDao(db),
            ),
          ),
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
    expect(find.text('CHANGES  1'), findsOneWidget);
    expect(find.text('main.dart'), findsOneWidget);
    expect(find.text('new.dart'), findsOneWidget);
  });

  testWidgets('staging one file adds that path and nothing else', (
    tester,
  ) async {
    await pump(tester, files: const [modified]);

    await tester.tap(find.byTooltip('Stage').first);
    await tester.pumpAndSettle();

    expect(ran().single, ['add', '--', 'lib/main.dart']);
  });

  testWidgets('unstaging restores the index, leaving the file alone', (
    tester,
  ) async {
    await pump(tester, files: const [stagedAdd]);

    await tester.tap(find.byTooltip('Unstage').first);
    await tester.pumpAndSettle();

    expect(ran().single, ['restore', '--staged', '--', 'lib/new.dart']);
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

    // An untracked file is cleaned, not restored — and the restore that runs
    // beside it is given no paths, so it never runs at all.
    expect(ran().single, ['clean', '-f', '-d', '--', 'scratch.txt']);
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

    expect(ran().single, [
      'restore',
      '--staged',
      '--worktree',
      '--',
      'lib/main.dart',
    ]);
  });

  testWidgets('with something staged, Commit commits what is staged', (
    tester,
  ) async {
    await pump(tester, files: const [stagedAdd, modified]);

    await tester.enterText(find.byType(TextField), 'a real message');
    await tester.tap(find.widgetWithText(FilledButton, 'Commit'));
    await tester.pumpAndSettle();

    expect(ran().single, ['commit', '-m', 'a real message']);
  });

  testWidgets('with nothing staged, the button says so and stages first', (
    tester,
  ) async {
    await pump(tester, files: const [modified]);

    expect(find.widgetWithText(FilledButton, 'Commit all'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'everything');
    await tester.tap(find.widgetWithText(FilledButton, 'Commit all'));
    await tester.pumpAndSettle();

    expect(ran(), [
      ['add', '-A'],
      ['commit', '-m', 'everything'],
    ]);
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
    runner.responder = (_) => const CommandResult(
      exitCode: 1,
      stdout: '',
      stderr: 'error: failed to push some refs to origin\n',
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

    expect(ran().single, ['push', '-u', 'origin', 'work']);
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

    expect(ran().single, ['pull', '--ff-only']);
  });
}
