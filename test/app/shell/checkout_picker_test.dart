import 'package:karmashala/src/app/shell/side_panel_context.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/application/checkout_picker.dart';
import 'package:karmashala/src/features/explorer/application/session_context.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/git/application/checkout_probe_queue.dart';
import 'package:karmashala/src/features/github/application/github_providers.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/repositories/application/repository_discovery_provider.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:karmashala/src/features/repositories/application/repository_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// Picking the checkout the repository-scoped surfaces describe.
///
/// The shape under test is the owner's own workspace: a hub project whose work
/// happens in a clone three folders down and in the `wt-*` worktrees beside it.
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

  /// Git as this workspace answers. The forward slashes are deliberate: that is
  /// what `git worktree list` reports on Windows, against a table of backslashes.
  CommandResult respond(CommandRequest request) {
    final verb = verbOf(request);
    final dir = dirOf(request);
    if (verb.take(2).join(' ') == 'worktree list') {
      // The clone owns both `wt-*` folders and says so whichever is asked.
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
      // Two formats for two calls: `statusWithBranch` asks for
      // `--porcelain=v2 --branch`, and `status` for a bare v1 file list.
      return CommandResult(
        exitCode: 0,
        stdout: verb.contains('--branch')
            ? porcelainV2(
                branch: branch,
                upstream: 'origin/$branch',
                modified: const ['lib/main.dart'],
              )
            : ' M lib/main.dart\n',
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
        checkoutPresenceProbeProvider.overrideWithValue(
          FakeCheckoutPresenceProbe(),
        ),
        // A real poll timer outlives the widget tree and trips the pending-timer
        // check; nothing here is testing the poll.
        deliveryPollIntervalProvider.overrideWithValue(Duration.zero),
        // These tests read a delivery future directly rather than through a
        // pump, so the real frame gate has no frame to wait for.
        probeGateProvider.overrideWithValue(headlessProbeGate),
        gitFilesProvider.overrideWithValue(noGitFiles),
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

      // All four, not the one the session happened to launch in.
      expect(find.text('demo'), findsWidgets);
      expect(find.text('app'), findsOneWidget);
      expect(find.text('wt-relay'), findsOneWidget);
      expect(find.text('wt-inbox'), findsOneWidget);

      // A worktree says so, and says which branch.
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

      // Two families, so two processes for four rows.
      final listings = git.requests
          .where((r) => verbOf(r).take(2).join(' ') == 'worktree list')
          .map(dirOf)
          .toList();
      expect(listings, hasLength(2));
      expect(listings, containsAll([hubPath, appPath]));
    });

    testWidgets('fits the panel dragged to its narrowest', (tester) async {
      // 240px is the side panel's minimum: a name, a sub-path and a caret.
      insertAllCheckouts();
      final container = makeContainer();
      container.read(selectedRepositoryIdProvider.notifier).select('inbox');
      tester.view.physicalSize = const Size(1400, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topRight,
                child: SizedBox(width: 240, child: SidePanelContextLine()),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);

      // The menu is an overlay, but still has to fit at the right edge.
      await openPicker(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('wt-relay'), findsOneWidget);
    });

    testWidgets('a project with one checkout still offers the rescan', (
      tester,
    ) async {
      // This used to draw no menu at all, and it is the whole of the owner's
      // complaint: a project whose only recorded checkout is its own root gave
      // no caret, nothing to click, and no way to say that the clone inside it
      // was simply never scanned for. A list of one is worth opening when the
      // thing under it is Rescan.
      RepositoryDao(
        db,
      ).insert(repository(id: 'hub', name: 'demo', path: hubPath));
      final container = makeContainer();
      container.read(selectedRepositoryIdProvider.notifier).select('hub');
      await pump(tester, container);

      expect(find.text('demo'), findsOneWidget);
      expect(find.byIcon(AppIcons.caretDown), findsOneWidget);

      await openPicker(tester);
      expect(find.text('Rescan for checkouts'), findsOneWidget);
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

      // Changes asks git in the picked directory…
      final changes = await container.read(repositoryChangesProvider.future);
      expect(changes, hasLength(1));
      expect(
        git.requests.where((r) => verbOf(r).contains('status')).map(dirOf),
        contains(relayPath),
      );

      // …and GitHub runs `gh` there, not in the hub.
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

      // Commit and Push are prompts driven by the scoped repository's delivery
      // state, which after the pick is read from the worktree.
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

      // A rescan rebuilds every provider the line reads; the pick survives it.
      discovery.result = const [];
      await container
          .read(projectsControllerProvider.notifier)
          .rediscover('p1');
      await tester.pumpAndSettle();
      expect(container.read(selectedRepositoryIdProvider), 'relay');

      // And a session change still wins — the rule that existed before.
      container.read(sessionContextProvider).follow('s-hub');
      expect(container.read(selectedRepositoryIdProvider), 'hub');
    });
  });

  testWidgets('a pick made in a session is given back when it returns', (
    tester,
  ) async {
    // The other half of the owner's report. The context recomputes the checkout
    // from the session's launch directory every time the active session
    // changes, so picking the clone the agents work in and then switching
    // terminal tabs put the panel back on the hub — which reads exactly like
    // the pick never happened.
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
        checkoutPresenceProbeProvider.overrideWithValue(
          FakeCheckoutPresenceProbe(),
        ),
        deliveryPollIntervalProvider.overrideWithValue(Duration.zero),
      ],
    );
    addTearDown(container.dispose);
    container.read(selectedRepositoryIdProvider.notifier).select('hub');
    await pump(tester, container);
    // The panel is showing s-hub's context, which is what a pick is filed
    // against.
    container.read(sessionContextProvider).follow('s-hub');
    await tester.pumpAndSettle();

    await openPicker(tester);
    await tester.tap(find.text('app'));
    await tester.pumpAndSettle();
    expect(container.read(selectedRepositoryIdProvider), 'app');

    // Another tab, then back: the session's own launch directory says 'hub',
    // and the pick says otherwise.
    container.read(sessionContextProvider).follow('s-hub');
    expect(
      container.read(selectedRepositoryIdProvider),
      'app',
      reason: 'a pick that a tab switch forgets is not a choice',
    );
  });

  testWidgets('a worktree created while the app runs appears after a rescan', (
    tester,
  ) async {
    // Agents cut worktrees while the app is open; the rescan is all it takes.
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
    // Offering another project's clones would move the Explorer under the user.
    ProjectDao(
      db,
    ).insert(project(id: 'p2', name: 'Other', path: r'C:\src\other'));
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

    expect(container.read(projectCheckoutsProvider).map((r) => r.id), [
      'other',
    ]);
  });

  testWidgets('a worktree chip selects the checkout it names', (tester) async {
    // The chips listed real worktrees but resolved them in the parents-only
    // list, so every one rendered greyed out and tapping it did nothing.
    insertAllCheckouts();
    final container = makeContainer();
    container.read(selectedRepositoryIdProvider.notifier).select('app');
    // The picker classifies checkouts lazily, so the chips only break once
    // something else has loaded the labels — which is the state the app is in.
    final sub = container.listen(checkoutLabelsProvider('p1'), (_, _) {});
    addTearDown(sub.close);
    await container.read(checkoutLabelsProvider('p1').future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: SidePanelWorktrees())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('dual-relay'));
    await tester.pumpAndSettle();
    expect(container.read(selectedCheckoutProvider)?.id, 'relay');
  });

  test('the worktree rows the picker filters out stay resolvable', () async {
    // `SidePanelWorktrees` turns a worktree path back into its row to decide
    // where its chip points. It looked that up in the parents-only list, so
    // every lookup missed and no chip was ever selectable.
    insertAllCheckouts();
    final container = makeContainer();
    container.read(selectedRepositoryIdProvider.notifier).select('app');
    final sub = container.listen(checkoutLabelsProvider('p1'), (_, _) {});
    addTearDown(sub.close);
    await container.read(checkoutLabelsProvider('p1').future);

    expect(
      container.read(projectCheckoutsProvider).map((r) => r.id),
      isNot(anyOf(contains('relay'), contains('inbox'))),
    );
    expect(
      container.read(projectCheckoutRowsProvider).map((r) => r.id),
      containsAll(['app', 'relay', 'inbox']),
    );
  });
}
