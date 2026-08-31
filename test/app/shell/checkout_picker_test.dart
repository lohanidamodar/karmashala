import 'package:chitragupta/src/app/shell/side_panel_context.dart';
import 'package:chitragupta/src/app/theme/app_icons.dart';
import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/core/process/command_runner_providers.dart';
import 'package:chitragupta/src/core/util/clock_provider.dart';
import 'package:chitragupta/src/core/util/id_generator_provider.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:chitragupta/src/features/cli_detection/application/project_import_service.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:chitragupta/src/features/explorer/application/checkout_picker.dart';
import 'package:chitragupta/src/features/explorer/application/session_context.dart';
import 'package:chitragupta/src/features/git/application/changes_providers.dart';
import 'package:chitragupta/src/features/github/application/github_providers.dart';
import 'package:chitragupta/src/features/projects/application/projects_controller.dart';
import 'package:chitragupta/src/features/repositories/application/repository_discovery_provider.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/repositories/domain/discovered_repository.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/sessions/application/delivery_providers.dart';
import 'package:chitragupta/src/features/sessions/data/session_dao.dart';
import 'package:chitragupta/src/features/sessions/domain/session.dart';
import 'package:chitragupta/src/features/sessions/domain/session_status.dart';
import 'package:chitragupta/src/features/sessions/domain/delivery_action.dart';
import 'package:chitragupta/src/features/repositories/domain/repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// Picking the checkout the repository-scoped surfaces describe.
///
/// The shape under test is the owner's own workspace: a hub project whose real
/// work happens in a clone three folders down and in the `wt-*` worktrees beside
/// it. A session's working directory is fixed at launch and its **subagents** are
/// the ones that move, so no amount of following one pane would put Changes and
/// GitHub on the right checkout. Being able to choose is what fixes it.
void main() {
  const hubPath = r'C:\src\demo';
  const appPath = r'C:\src\demo\projects\app';
  const relayPath = r'C:\src\demo\projects\wt-relay';
  const inboxPath = r'C:\src\demo\projects\wt-inbox';

  late AppDatabase db;
  late FakeCommandRunner git;
  late FakeRepositoryDiscoveryService discovery;

  EnvironmentPath at(String path) =>
      EnvironmentPath(environmentId: 'windows', path: path);

  /// The directory `git -C <dir> …` was pointed at.
  String dirOf(CommandRequest request) =>
      request.arguments.length > 1 ? request.arguments[1] : '';

  List<String> verbOf(CommandRequest request) =>
      request.arguments.skip(2).toList();

  /// Git as this workspace really answers. Note the forward slashes: on Windows
  /// `git worktree list` reports them, while the `repositories` table holds
  /// backslashes — the picker has to see through that or every row is a stranger.
  CommandResult respond(CommandRequest request) {
    final verb = verbOf(request);
    final dir = dirOf(request);
    if (verb.take(2).join(' ') == 'worktree list') {
      // The hub is its own one-worktree repository. The clone under it owns the
      // two `wt-*` folders, and says so whichever of the three is asked.
      final porcelain = dir == hubPath
          ? 'worktree C:/src/demo\nHEAD aaa\nbranch refs/heads/main\n\n'
          : 'worktree C:/src/demo/projects/app\n'
                'HEAD bbb\nbranch refs/heads/main\n\n'
                'worktree C:/src/demo/projects/wt-relay\n'
                'HEAD ccc\nbranch refs/heads/dual-relay\n\n'
                'worktree C:/src/demo/projects/wt-inbox\n'
                'HEAD ddd\nbranch refs/heads/inbox-bounds\n\n';
      return CommandResult(exitCode: 0, stdout: porcelain, stderr: '');
    }
    if (verb.first == 'status') {
      final branch = switch (dir) {
        relayPath => 'dual-relay',
        inboxPath => 'inbox-bounds',
        _ => 'main',
      };
      // The `##` header only when it was asked for: a plain `git status
      // --porcelain` that emits one is a status with a phantom changed file.
      final header = verb.contains('--branch')
          ? '## $branch...origin/$branch\n'
          : '';
      return CommandResult(
        exitCode: 0,
        stdout: '$header M lib/main.dart\n',
        stderr: '',
      );
    }
    if (verb.take(2).join(' ') == 'remote get-url') {
      return const CommandResult(
        exitCode: 0,
        stdout: 'git@github.com:popupbits/demo.git\n',
        stderr: '',
      );
    }
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  /// Every checkout in the hub project, in the order discovery records them.
  void insertAllCheckouts() {
    RepositoryDao(db)
      ..insert(repository(id: 'hub', name: 'demo', path: hubPath))
      ..insert(repository(id: 'app', name: 'app', path: appPath))
      ..insert(repository(id: 'relay', name: 'wt-relay', path: relayPath))
      ..insert(repository(id: 'inbox', name: 'wt-inbox', path: inboxPath));
  }

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project(id: 'p1', name: 'Demo', path: hubPath));
    AgentInstallationDao(db).insert(agentInstallation());
    git = FakeCommandRunner(responder: respond);
    discovery = FakeRepositoryDiscoveryService();
  });
  tearDown(() => db.close());

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('n-')),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: git),
        ),
        autoImportRunnerProvider.overrideWithValue(
          (repos) async => const ImportSummary(),
        ),
        repositoryDiscoveryServiceProvider.overrideWithValue(discovery),
        // A real poll timer outlives the widget tree and trips the pending-timer
        // check; nothing here is testing the poll.
        deliveryPollIntervalProvider.overrideWithValue(Duration.zero),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> pump(WidgetTester tester, ProviderContainer container) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SidePanelContextLine(),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openPicker(WidgetTester tester) async {
    await tester.tap(find.byType(SidePanelContextLine));
    await tester.pumpAndSettle();
  }

  group('the list', () {
    testWidgets('offers every checkout the project holds, labelled', (
      tester,
    ) async {
      insertAllCheckouts();
      final container = makeContainer();
      container.read(selectedRepositoryIdProvider.notifier).select('hub');
      await pump(tester, container);
      await openPicker(tester);

      // A nested clone and two worktrees beside it — all four, not the one the
      // session happened to launch in.
      expect(find.text('demo'), findsWidgets);
      expect(find.text('app'), findsOneWidget);
      expect(find.text('wt-relay'), findsOneWidget);
      expect(find.text('wt-inbox'), findsOneWidget);

      // A worktree says so, and says which branch — `wt-relay` and the clone it
      // was cut from must not read as two identical rows.
      expect(
        find.text('worktree  ·  dual-relay  ·  projects/wt-relay'),
        findsOneWidget,
      );
      expect(
        find.text('worktree  ·  inbox-bounds  ·  projects/wt-inbox'),
        findsOneWidget,
      );
      // The clone is a main checkout, so no worktree word — just its branch.
      expect(find.text('main  ·  projects/app'), findsOneWidget);
      expect(find.text('main  ·  project root'), findsOneWidget);
    });

    testWidgets('costs one `git worktree list` per family, not per row', (
      tester,
    ) async {
      insertAllCheckouts();
      final container = makeContainer();
      container.read(selectedRepositoryIdProvider.notifier).select('hub');
      await pump(tester, container);

      // Nothing has run yet: the panel being on screen scans nothing.
      expect(git.requests, isEmpty);

      await openPicker(tester);

      // Two families — the hub, and the clone that owns both worktrees — so two
      // processes for four rows.
      final listings = git.requests
          .where((r) => verbOf(r).take(2).join(' ') == 'worktree list')
          .map(dirOf)
          .toList();
      expect(listings, hasLength(2));
      expect(listings, containsAll([hubPath, appPath]));
    });

    testWidgets('a project with one checkout shows no picker', (tester) async {
      RepositoryDao(db).insert(
        repository(id: 'hub', name: 'demo', path: hubPath),
      );
      final container = makeContainer();
      container.read(selectedRepositoryIdProvider.notifier).select('hub');
      await pump(tester, container);

      // Exactly what it drew before there was a picker: a name, no caret, and
      // nothing to press.
      expect(find.text('demo'), findsOneWidget);
      expect(find.byType(PopupMenuButton<Repository>), findsNothing);
      expect(find.byIcon(AppIcons.caretDown), findsNothing);
    });
  });

  group('the pick', () {
    testWidgets('moves Changes and GitHub to the checkout chosen', (
      tester,
    ) async {
      insertAllCheckouts();
      final container = makeContainer();
      container.read(selectedRepositoryIdProvider.notifier).select('hub');
      await pump(tester, container);
      await openPicker(tester);
      await tester.tap(find.text('wt-relay'));
      await tester.pumpAndSettle();

      expect(container.read(selectedRepositoryIdProvider), 'relay');

      // The surfaces read that one selection, so both follow it: Changes asks
      // git in the picked directory…
      final changes = await container.read(repositoryChangesProvider.future);
      expect(changes, hasLength(1));
      expect(
        git.requests.where((r) => verbOf(r).contains('status')).map(dirOf),
        contains(relayPath),
      );

      // …and GitHub runs `gh` there, not in the hub the session launched in.
      await container.read(githubPullRequestsProvider.future);
      final gh = git.requests
          .where((r) => r.executable == 'gh')
          .map((r) => r.workingDirectory?.path);
      expect(gh, isNotEmpty);
      expect(gh, everyElement(relayPath));
    });

    testWidgets('commit and push act on the checkout chosen', (tester) async {
      insertAllCheckouts();
      final container = makeContainer();
      container.read(selectedRepositoryIdProvider.notifier).select('hub');
      await pump(tester, container);
      await openPicker(tester);
      await tester.tap(find.text('wt-relay'));
      await tester.pumpAndSettle();

      // Commit and Push are prompts driven by the delivery state of the
      // repository the panel is scoped to. After the pick that state is read
      // from the worktree, so the branch they would act on is its branch.
      final id = container.read(selectedRepositoryIdProvider)!;
      final delivery = await container.read(
        repositoryDeliveryProvider(id).future,
      );
      expect(delivery.branch, 'dual-relay');
      expect(delivery.dirtyFiles, 1);
      expect(
        deliveryActionsFor(delivery).map((a) => a.action),
        contains(DeliveryAction.commit),
      );
    });

    testWidgets('holds while panes change, and yields to a new session', (
      tester,
    ) async {
      insertAllCheckouts();
      SessionDao(db).insert(
        Session(
          id: 's-hub',
          repositoryId: 'hub',
          agentInstallationId: 'a1',
          title: 'Rooted at the hub',
          useWorktree: false,
          status: SessionStatus.running,
          createdAt: testTime,
        ),
      );
      final container = makeContainer();
      container.read(selectedRepositoryIdProvider.notifier).select('hub');
      await pump(tester, container);
      await openPicker(tester);
      await tester.tap(find.text('wt-relay'));
      await tester.pumpAndSettle();
      expect(container.read(selectedRepositoryIdProvider), 'relay');

      // The workspace changing under the panel does not write the selection —
      // only an active-session *change* does. A rescan rebuilds every provider
      // the line reads, and the pick is still the pick afterwards.
      discovery.result = const [];
      await container.read(projectsControllerProvider.notifier).rediscover('p1');
      await tester.pumpAndSettle();
      expect(container.read(selectedRepositoryIdProvider), 'relay');

      // And the session change still wins, which is the rule that existed
      // before the picker did.
      container.read(sessionContextProvider).follow('s-hub');
      expect(container.read(selectedRepositoryIdProvider), 'hub');
    });
  });

  testWidgets('a worktree created while the app runs appears after a rescan', (
    tester,
  ) async {
    // The owner's agents cut worktrees while the app is open. Discovery already
    // counts a `.git` **file** as a checkout, so the rescan is all it takes.
    RepositoryDao(db)
      ..insert(repository(id: 'hub', name: 'demo', path: hubPath))
      ..insert(repository(id: 'app', name: 'app', path: appPath));
    final container = makeContainer();
    container.read(selectedRepositoryIdProvider.notifier).select('app');
    await pump(tester, container);
    await openPicker(tester);
    expect(find.text('wt-relay'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuItem<Repository>), findsNothing);

    discovery.result = [
      DiscoveredRepository(name: 'demo', path: at(hubPath)),
      DiscoveredRepository(name: 'app', path: at(appPath)),
      DiscoveredRepository(name: 'wt-relay', path: at(relayPath)),
    ];
    await container.read(projectsControllerProvider.notifier).rediscover('p1');
    await tester.pumpAndSettle();

    await openPicker(tester);
    expect(find.text('wt-relay'), findsOneWidget);
    expect(
      find.text('worktree  ·  dual-relay  ·  projects/wt-relay'),
      findsOneWidget,
    );
  });

  test('the picker only ever offers checkouts of one project', () {
    // Two projects, and the panel pointed at the second. Offering the first
    // project's clones would move the Explorer out from under the user.
    ProjectDao(db).insert(
      project(id: 'p2', name: 'Other', path: r'C:\src\other'),
    );
    insertAllCheckouts();
    RepositoryDao(db).insert(
      repository(
        id: 'other',
        projectId: 'p2',
        name: 'other',
        path: r'C:\src\other',
      ),
    );
    final container = makeContainer();
    container.read(selectedRepositoryIdProvider.notifier).select('other');

    expect(
      container.read(projectCheckoutsProvider).map((r) => r.id),
      ['other'],
    );
  });
}
