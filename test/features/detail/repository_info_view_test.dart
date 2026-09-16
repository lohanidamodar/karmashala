import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/detail/presentation/repository_info_view.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/explorer/application/picked_checkouts.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../terminal/fake_instance.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';

void main() {
  group('webUrlForRemote', () {
    test('scp syntax becomes a browsable URL', () {
      expect(
        webUrlForRemote('git@github.com:popupbits/karmashala.git'),
        'https://github.com/popupbits/karmashala',
      );
    });

    test('an ssh:// URL becomes one too', () {
      expect(
        webUrlForRemote('ssh://git@gitlab.com/group/sub/app.git'),
        'https://gitlab.com/group/sub/app',
      );
    });

    test('an https remote just loses its .git', () {
      expect(
        webUrlForRemote('https://github.com/popupbits/karmashala.git'),
        'https://github.com/popupbits/karmashala',
      );
    });

    test('a local remote is not a link', () {
      // Each of these has been a real remote; none of them is somewhere a
      // browser can go, and offering a dead link is worse than plain text.
      expect(webUrlForRemote(r'C:\src\mirror\app.git'), isNull);
      expect(webUrlForRemote('/srv/git/app.git'), isNull);
      expect(webUrlForRemote('../sibling.git'), isNull);
      expect(webUrlForRemote(''), isNull);
      expect(webUrlForRemote('none'), isNull);
    });
  });

  group('RepositoryInfoView', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.memory();
      ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
      ProjectDao(db).insert(project());
      RepositoryDao(db).insert(repository());
    });
    tearDown(() => db.close());

    Future<ProviderContainer> pump(WidgetTester tester) async {
      final container = ProviderContainer(
        overrides: fakeTerminalOverrides(database: db),
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: RepositoryInfoView())),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('with nothing selected it says what to select', (tester) async {
      await pump(tester);

      expect(find.byType(PanePlaceholder), findsOneWidget);
    });

    testWidgets('a project without a repository says what is missing', (
      tester,
    ) async {
      // The surface the owner could not find: with a project chosen and no
      // repository it rendered two rows and stopped, with nothing to say the
      // branch and worktree list was one more click away.
      final container = await pump(tester);
      container.read(selectedProjectIdProvider.notifier).select('p1');
      await tester.pumpAndSettle();

      expect(
        find.text('Select a repository to see its branches and worktrees.'),
        findsOneWidget,
      );
      expect(find.text('WORKTREES'), findsNothing);
    });

    testWidgets('choosing the repository brings the git sections', (
      tester,
    ) async {
      final container = await pump(tester);
      container.read(selectedProjectIdProvider.notifier).select('p1');
      container.read(selectedRepositoryIdProvider.notifier).select('r1');
      await tester.pumpAndSettle();

      expect(find.text('GIT'), findsOneWidget);
      expect(find.text('WORKTREES'), findsOneWidget);
      expect(
        find.text('Select a repository to see its branches and worktrees.'),
        findsNothing,
      );
    });
  });

  /// **The worktree list, and the two things you can do to a row.**
  ///
  /// The owner had eight worktrees in flight, listed flat and expanded, and
  /// PROJECT and PROJECT ROOT were pushed off the bottom of the panel — with
  /// nothing to click on any of them. Clicking now *reads* one; the switch that
  /// moves the app's checkout is a second, named verb behind the row's menu.
  group('RepositoryInfoView worktrees', () {
    const homePath = r'C:\src\demo\app';
    // As long as the branches this repository's own agents cut.
    const longBranch = 'agents/loop-73-worktree-navigation-and-a-long-name';

    late AppDatabase db;
    late List<GitWorktree> worktrees;

    EnvironmentPath at(String path) =>
        EnvironmentPath(environmentId: 'windows', path: path);

    List<GitWorktree> family(int count) => [
      GitWorktree(path: at(homePath), branch: 'main'),
      for (var i = 1; i < count; i++)
        GitWorktree(
          path: at('C:\\src\\demo\\wt\\agent-$i'),
          branch: i == 1 ? longBranch : 'agent-$i',
        ),
    ];

    setUp(() {
      db = AppDatabase.memory();
      ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
      ProjectDao(db).insert(project());
      RepositoryDao(db).insert(repository());
      worktrees = family(8);
    });
    tearDown(() => db.close());

    ProviderContainer container() {
      final container = ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(database: db),
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
          ),
          repoWorktreesProvider.overrideWith((ref) async => worktrees),
          currentBranchProvider.overrideWith((ref) async => 'main'),
          repoRemoteUrlProvider.overrideWith((ref) async => null),
          recentCommitsProvider.overrideWith(
            (ref) async => const <GitCommit>[],
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(selectedProjectIdProvider.notifier).select('p1');
      container.read(selectedRepositoryIdProvider.notifier).select('r1');
      return container;
    }

    Widget pane(ProviderContainer scope) => UncontrolledProviderScope(
      container: scope,
      child: const MaterialApp(
        // The panel's own width, which is what makes the list expensive.
        home: Scaffold(
          body: SizedBox(width: 240, child: RepositoryInfoView()),
        ),
      ),
    );

    Future<ProviderContainer> pump(WidgetTester tester) async {
      final scope = container();
      await tester.pumpWidget(pane(scope));
      await tester.pumpAndSettle();
      return scope;
    }

    testWidgets('eight worktrees stay shut, and the count says how many', (
      tester,
    ) async {
      await pump(tester);

      expect(find.text('WORKTREES'), findsOneWidget);
      expect(find.text('8'), findsOneWidget);
      expect(find.text(longBranch), findsNothing);
      expect(find.text('agent-7'), findsNothing);
      // The facts underneath are what the list was burying.
      expect(find.text('RECENT COMMITS'), findsOneWidget);
    });

    testWidgets('opening the section lists them, and closing puts them away', (
      tester,
    ) async {
      await pump(tester);

      await tester.tap(find.text('WORKTREES'));
      await tester.pumpAndSettle();
      expect(find.text(longBranch), findsOneWidget);

      // Bounded: the eighth is not on screen, and is reached by scrolling the
      // section rather than by the section growing until the panel is full.
      expect(find.text('agent-7'), findsNothing);
      await tester.drag(find.text('agent-2'), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(find.text('agent-7'), findsOneWidget);

      await tester.tap(find.text('WORKTREES'));
      await tester.pumpAndSettle();
      expect(find.text('agent-7'), findsNothing);
      expect(find.text(longBranch), findsNothing);
    });

    testWidgets('a short list opens itself', (tester) async {
      worktrees = family(3);
      await pump(tester);

      expect(find.text('agent-2'), findsOneWidget);
    });

    testWidgets('clicking a worktree reads it and moves nothing else', (
      tester,
    ) async {
      final scope = await pump(tester);
      await tester.tap(find.text('WORKTREES'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('agent-2'));
      await tester.pumpAndSettle();

      expect(
        scope.read(viewedCheckoutProvider)?.path,
        r'C:\src\demo\wt\agent-2',
      );
      // Said out loud, and still said with the list shut.
      expect(find.text('viewing agent-2'), findsOneWidget);
      await tester.tap(find.text('WORKTREES'));
      await tester.pumpAndSettle();
      expect(find.text('viewing agent-2'), findsOneWidget);
      expect(find.text('agent-2'), findsOneWidget);

      // Neither of the two things that decide where an agent runs moved.
      expect(scope.read(selectedRepositoryIdProvider), 'r1');
      expect(scope.read(pickedCheckoutsProvider), isEmpty);
    });

    testWidgets('the checkout row is the way back', (tester) async {
      final scope = await pump(tester);
      await tester.tap(find.text('WORKTREES'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('agent-2'));
      await tester.pumpAndSettle();

      // The GIT section names the branch too, and the row is the later of the
      // two — this is the list, not the field above it.
      await tester.tap(find.text('main').last);
      await tester.pumpAndSettle();

      expect(scope.read(worktreeBrowsingProvider), isNull);
      expect(scope.read(viewedCheckoutProvider)?.path, homePath);
      expect(find.textContaining('viewing'), findsNothing);
    });

    testWidgets('the row menu offers the switch, and that one does move it', (
      tester,
    ) async {
      // The explicit verb: `CheckoutPicker`, the same call behind the panel's
      // picker and the `select_checkout` tool.
      RepositoryDao(db).insert(
        repository(
          id: 'r2',
          name: 'agent-2',
          path: r'C:\src\demo\wt\agent-2',
        ),
      );
      final scope = await pump(tester);
      await tester.tap(find.text('WORKTREES'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.text('agent-2'),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text("Select as the session's checkout"));
      await tester.pumpAndSettle();

      expect(scope.read(selectedRepositoryIdProvider), 'r2');
    });

    testWidgets('a worktree the workspace never recorded says so', (
      tester,
    ) async {
      final scope = await pump(tester);
      await tester.tap(find.text('WORKTREES'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.text('agent-2'),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text("Select as the session's checkout"));
      await tester.pumpAndSettle();

      expect(find.textContaining('rescan the project'), findsOneWidget);
      expect(scope.read(selectedRepositoryIdProvider), 'r1');
    });

    testWidgets('the open list survives the window matrix', (tester) async {
      final scope = container();

      await expectSurvivesWindowMatrix(
        tester,
        build: () => pane(scope),
        warmUp: (tester) async {
          await tester.tap(find.text('WORKTREES'));
          await tester.pump();
          expect(find.text(longBranch), findsOneWidget);
        },
        because:
            'eight worktrees, one of them on a branch longer than the panel '
            'is wide, in 240px',
      );
    });
  });
}
