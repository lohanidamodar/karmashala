import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/detail/presentation/repository_info_view.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala/src/features/git/presentation/changes_view.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
import '../terminal/fake_instance.dart';

/// **The three states a pane can be in when it has no git facts, and the words
/// each one gets.**
///
/// The owner's report: *"the side panes, when session i selected is not a git it
/// stays loading for a long time and then shows git exception, it should be
/// handled correctly in repo, changes etc panes."* What was on screen was
/// `GitException: git status failed: fatal: not a git repository …` in a red
/// box — an internal type name for the most ordinary situation an agent works
/// in, and one red box for both a folder that is fine and a git that is broken.
///
/// Three states, told apart in one place (`gitTroubleOf`) so the panes cannot
/// word the same failure two ways, and separated the way §19 separates a health
/// row's: an unobserved state must not borrow an observed one's words.
///
/// | state            | observed?           | how it reads               |
/// | ---------------- | ------------------- | -------------------------- |
/// | not a repository | yes, a fact         | calm, muted, a folder icon |
/// | could not reach  | no — we don't know  | calm, muted, a broken link |
/// | git failed       | yes, a fault        | the red box, git's words   |
void main() {
  /// §11's compact cell. These are side panes that are dragged narrow, so the
  /// phone width is also the realistic narrow-panel width.
  const phone = WindowCell('390x844 (phone)', Size(390, 844));

  late AppDatabase db;

  const checkout = EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\src\demo\app',
  );

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
  });
  tearDown(() => db.close());

  /// The three errors the panes have to tell apart, as they arrive.
  const notARepository = NotAGitRepository(checkout);
  final unreachable = CommandException(
    'Failed to run "git" in WSL "Ubuntu"',
  );
  final failed = GitException(
    'git status failed: fatal: detected dubious ownership in repository',
  );

  /// Past `defaultRetry`'s ten attempts, whose backoff sums to 38.2 s.
  ///
  /// Only [GitTrouble.failed] retries at all, and this proves the panes read
  /// the same either side of it. The two settled verdicts never reach this
  /// clock, which is the point of `_retryOnlyRealFailures`.
  Future<void> pastTheRetries(WidgetTester tester) =>
      tester.pump(const Duration(minutes: 2));

  /// Every git provider failing the same way, which is what actually happens: a
  /// folder with no git in it has nothing for any of them. Inline for the
  /// reason [headlessProbeGate] gives — `Override` is not exported.
  ProviderContainer containerFailingWith(Object error) {
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        repositoryChangesProvider.overrideWith((ref) async => throw error),
        repoWorktreesProvider.overrideWith((ref) async => throw error),
        currentBranchProvider.overrideWith((ref) async => throw error),
        repoRemoteUrlProvider.overrideWith((ref) async => throw error),
        recentCommitsProvider.overrideWith((ref) async => throw error),
      ],
    );
    addTearDown(container.dispose);
    container.read(selectedProjectIdProvider.notifier).select('p1');
    container.read(selectedRepositoryIdProvider.notifier).select('r1');
    return container;
  }

  group('the Changes pane', () {
    Future<void> pump(WidgetTester tester, Object error) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: containerFailingWith(error),
          child: const MaterialApp(
            home: Scaffold(body: ChangesView(repositoryName: 'app')),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a folder that is not a repository is stated, calmly', (
      tester,
    ) async {
      await pump(tester, notARepository);

      expect(find.text(notARepositoryMessage), findsOneWidget);
      // Not the red box, and no exception name anywhere on the surface.
      expect(find.byType(PanePlaceholder), findsOneWidget);
      expect(find.textContaining('GitException'), findsNothing);
      expect(find.textContaining('NotAGitRepository'), findsNothing);
      expect(find.textContaining('fatal:'), findsNothing);
    });

    testWidgets('a checkout that could not be reached says so instead', (
      tester,
    ) async {
      // A stopped WSL distribution must never read as "your repository is not
      // a repository".
      await pump(tester, unreachable);

      expect(find.text(gitUnreachableMessage), findsOneWidget);
      expect(find.text(notARepositoryMessage), findsNothing);
    });

    testWidgets('a real git failure keeps the red box and git\'s own words', (
      tester,
    ) async {
      await pump(tester, failed);

      expect(find.textContaining('dubious ownership'), findsOneWidget);
      expect(find.byType(PanePlaceholder), findsNothing);
    });

    testWidgets('the calm state fits a phone and a desktop', (tester) async {
      await expectSurvivesWindowMatrix(
        tester,
        matrix: const [phone, desktopWindow],
        build: () => UncontrolledProviderScope(
          container: containerFailingWith(notARepository),
          child: const MaterialApp(
            home: Scaffold(body: ChangesView(repositoryName: 'app')),
          ),
        ),
        because: 'a paragraph in a pane that is dragged narrow',
      );
    });
  });

  group('the Repository pane', () {
    Future<void> pump(WidgetTester tester, Object error) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: containerFailingWith(error),
          child: const MaterialApp(
            home: Scaffold(body: RepositoryInfoView()),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the whole GIT section becomes one sentence', (tester) async {
      // Four rows each saying "not a git repository" in a 240px panel is the
      // same fact spelled four times.
      await pump(tester, notARepository);

      expect(find.text('GIT'), findsOneWidget);
      expect(find.text(notARepositoryMessage), findsOneWidget);
      expect(find.text('Branch'), findsNothing);
      expect(find.text('Remote'), findsNothing);
      expect(find.text('WORKTREES'), findsNothing);
      expect(find.text('RECENT COMMITS'), findsNothing);
      // The rows above GIT still describe the folder, which is the useful part
      // of this pane for a session that is not in a repository.
      expect(find.text(r'C:\src\demo\app'), findsOneWidget);
    });

    testWidgets('an unreachable checkout is not a folder without git', (
      tester,
    ) async {
      await pump(tester, unreachable);

      expect(find.text(gitUnreachableMessage), findsOneWidget);
      expect(find.text(notARepositoryMessage), findsNothing);
    });

    testWidgets('a real failure shows git\'s own words, once', (tester) async {
      await pump(tester, failed);
      // Straight away, not after the 38 s of backoff: the two panes have to say
      // the same thing at the same time.
      expect(find.textContaining('dubious ownership'), findsOneWidget);

      await pastTheRetries(tester);
      expect(find.textContaining('dubious ownership'), findsOneWidget);
    });

    testWidgets('a row that fails on its own is named, not "unavailable"', (
      tester,
    ) async {
      // The section-wide note comes off the worktree listing; a remote that
      // failed alone still has to name which of the three it was.
      final container = ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(database: db),
          repoWorktreesProvider.overrideWith(
            (ref) async => const <GitWorktree>[],
          ),
          currentBranchProvider.overrideWith((ref) async => 'main'),
          repoRemoteUrlProvider.overrideWith((ref) async => throw unreachable),
          recentCommitsProvider.overrideWith((ref) async => throw failed),
          repositoryChangesProvider.overrideWith(
            (ref) async => const <FileChange>[],
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(selectedProjectIdProvider.notifier).select('p1');
      container.read(selectedRepositoryIdProvider.notifier).select('r1');

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: RepositoryInfoView()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await pastTheRetries(tester);

      expect(find.text('main'), findsOneWidget);
      expect(find.text('could not be reached'), findsOneWidget);
      expect(find.text('git failed'), findsOneWidget);
      expect(find.text('unavailable'), findsNothing);
    });

    testWidgets('the calm state fits a phone and a desktop', (tester) async {
      await expectSurvivesWindowMatrix(
        tester,
        matrix: const [phone, desktopWindow],
        build: () => UncontrolledProviderScope(
          container: containerFailingWith(notARepository),
          child: const MaterialApp(
            home: Scaffold(body: RepositoryInfoView()),
          ),
        ),
        because: 'a wrapping paragraph where four rows used to be',
      );
    });
  });

  group('a repository that is fine is untouched', () {
    testWidgets('the GIT section still draws all three of its parts', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(database: db),
          repoWorktreesProvider.overrideWith(
            (ref) async => const <GitWorktree>[],
          ),
          currentBranchProvider.overrideWith((ref) async => 'main'),
          repoRemoteUrlProvider.overrideWith(
            (ref) async => 'https://github.com/acme/app.git',
          ),
          recentCommitsProvider.overrideWith(
            (ref) async => const [
              GitCommit(sha: 'abcdef1234', author: 'me', subject: 'a commit'),
            ],
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(selectedProjectIdProvider.notifier).select('p1');
      container.read(selectedRepositoryIdProvider.notifier).select('r1');

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: RepositoryInfoView()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Branch'), findsOneWidget);
      expect(find.text('WORKTREES'), findsOneWidget);
      expect(find.text('RECENT COMMITS'), findsOneWidget);
      expect(find.text(notARepositoryMessage), findsNothing);
    });
  });
}
