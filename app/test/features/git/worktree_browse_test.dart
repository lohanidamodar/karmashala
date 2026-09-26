import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/explorer/application/picked_checkouts.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/git/application/diff_tab_actions.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala/src/features/git/presentation/changes_view.dart';
import 'package:karmashala/src/features/git/presentation/worktree_browse.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
import '../../support/fake_data_server.dart';
import '../../support/workspace_mirror.dart';

/// **Browsing a worktree, and what it is allowed to touch.**
///
/// The Changes pane can be pointed at any worktree of the selected checkout.
/// That is a view state and nothing else: no `repositories` row is selected, no
/// pick is remembered against a session, and no session directory is written —
/// so comparing two agents' worktrees cannot move where the next agent runs.
/// The explicit verb that *does* move the selection lives in the Repository
/// pane and goes through `CheckoutPicker`.
void main() {
  late FakeDataServer server;
  late DataClient client;
  const environmentId = 'windows';
  const homePath = r'C:\src\demo\app';
  const pathA = r'C:\src\demo\wt\agent-a';
  const pathB = r'C:\src\demo\wt\agent-b';
  // As long as the branches this repository's own agents cut, which is what
  // makes a 240px panel interesting.
  const longBranch = 'agents/loop-73-worktree-navigation-and-a-long-name';

  EnvironmentPath at(String path) =>
      EnvironmentPath(environmentId: environmentId, path: path);

  GitWorktree worktreeAt(String path, String branch) =>
      GitWorktree(path: at(path), branch: branch);

  FileChange change(String path) => FileChange(
    path: path,
    type: FileChangeType.modified,
    staged: false,
    unstaged: true,
  );

  late AppDatabase db;
  late List<GitWorktree> worktrees;
  late Map<String, List<FileChange>> changesByPath;

  setUp(() async {
    db = AppDatabase.memory();
    server = FakeDataServer()..mirrorInto(db);
    server.environmentRows.upsert(
  localHostEnvironment(FixedClock(testTime).nowUtc()),
);
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    client = await server.connect();
    worktrees = [
      worktreeAt(homePath, 'main'),
      worktreeAt(pathA, longBranch),
      worktreeAt(pathB, 'agent-b'),
    ];
    changesByPath = {
      homePath: [change('lib/main.dart')],
      pathA: [change('lib/from_a.dart')],
      pathB: [change('lib/from_b.dart')],
    };
  });
  tearDown(() => db.close());

  ProviderContainer container() {
    final container = ProviderContainer(
      overrides: [
        // No workbench here, so no diff tab: the real provider would build
        // the terminal controller and leave its autosave timer pending.
        activeDiffFileProvider.overrideWithValue(null),
        databaseProvider.overrideWithValue(db),
        dataClientProvider.overrideWithValue(client),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
        ),
        deliveryPollIntervalProvider.overrideWithValue(Duration.zero),
        repoWorktreesProvider.overrideWith((ref) async => worktrees),
        recentCommitsProvider.overrideWith((ref) async => const <GitCommit>[]),
        repositoryDeliveryProvider.overrideWith(
          (ref, _) async => SessionDelivery.unknown,
        ),
        // The whole point of the wiring: the file list is read from whichever
        // tree the pane is pointed at.
        repositoryChangesProvider.overrideWith((ref) async {
          final path = ref.watch(viewedCheckoutProvider);
          return changesByPath[path?.path] ?? const <FileChange>[];
        }),
      ],
    );
    addTearDown(container.dispose);
    container.read(selectedRepositoryIdProvider.notifier).select('r1');
    return container;
  }

  Widget pane(ProviderContainer container) => UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      // The panel's own width: everything here has to fit it.
      home: Scaffold(
        body: SizedBox(width: 240, child: ChangesView(repositoryName: 'app')),
      ),
    ),
  );

  Future<ProviderContainer> pump(WidgetTester tester) async {
    final scope = container();
    await tester.pumpWidget(pane(scope));
    await tester.pumpAndSettle();
    return scope;
  }

  Future<void> pick(WidgetTester tester, String label) async {
    await tester.tap(find.byType(WorktreeBrowsePicker));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('picking a worktree reads it, and moves nothing else', (
    tester,
  ) async {
    final scope = await pump(tester);
    expect(find.text('main.dart'), findsOneWidget);

    await pick(tester, longBranch);

    expect(find.text('from_a.dart'), findsOneWidget);
    expect(find.text('main.dart'), findsNothing);
    // The header names what it is reading rather than leaving it implicit.
    expect(find.text(longBranch), findsOneWidget);

    // Nothing that decides where an agent runs has moved: not the selection
    // `select_checkout` writes, and not the pick it remembers per session.
    expect(scope.read(selectedRepositoryIdProvider), 'r1');
    expect(scope.read(pickedCheckoutsProvider), isEmpty);
    expect(scope.read(worktreeBrowsingProvider)?.path.path, pathA);
  });

  testWidgets('the checkout itself is the way back', (tester) async {
    final scope = await pump(tester);
    await pick(tester, longBranch);
    expect(find.text('from_a.dart'), findsOneWidget);

    await pick(tester, 'main');

    expect(find.text('main.dart'), findsOneWidget);
    expect(scope.read(worktreeBrowsingProvider), isNull);
  });

  testWidgets('a worktree removed under you says so and falls back', (
    tester,
  ) async {
    // Agents create and destroy these constantly; eight existed when the owner
    // took the screenshot that started this. One vanishing must not leave an
    // empty pane with no explanation.
    final scope = await pump(tester);
    await pick(tester, 'agent-b');
    expect(find.text('from_b.dart'), findsOneWidget);

    worktrees = [worktreeAt(homePath, 'main'), worktreeAt(pathA, longBranch)];
    scope.invalidate(repoWorktreesProvider);
    await tester.pumpAndSettle();

    expect(find.textContaining('is gone'), findsOneWidget);
    expect(find.text('main.dart'), findsOneWidget);
    expect(scope.read(viewedCheckoutProvider)?.path, homePath);

    await tester.tap(find.byTooltip('Stop reading the removed worktree'));
    await tester.pumpAndSettle();
    expect(find.textContaining('is gone'), findsNothing);
    expect(scope.read(worktreeBrowsingProvider), isNull);
  });

  testWidgets('a loading worktree list is not a claim that anything is gone', (
    tester,
  ) async {
    final scope = container();
    scope
        .read(worktreeBrowsingProvider.notifier)
        .browse(
          WorktreeBrowse(
            repositoryId: 'r1',
            path: at(pathA),
            branch: longBranch,
          ),
        );
    await tester.pumpWidget(pane(scope));
    // One frame only: `git worktree list` has not answered yet.
    await tester.pump();

    expect(find.textContaining('is gone'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.textContaining('is gone'), findsNothing);
  });

  testWidgets('the Changes header survives the window matrix while browsing', (
    tester,
  ) async {
    final scope = container();
    scope
        .read(worktreeBrowsingProvider.notifier)
        .browse(
          WorktreeBrowse(
            repositoryId: 'r1',
            path: at(pathA),
            branch: longBranch,
          ),
        );

    await expectSurvivesWindowMatrix(
      tester,
      build: () => pane(scope),
      warmUp: (tester) async {
        await tester.tap(find.byType(WorktreeBrowsePicker));
        await tester.pump();
        expect(find.text('the selected checkout'), findsOneWidget);
      },
      because:
          'the header carries a picker, a long branch name and a file count '
          'in 240px, and the open menu lists three paths',
    );
  });
}
