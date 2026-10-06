import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/explorer/application/checkout_picker.dart';
import 'package:karmashala/src/features/file_explorer/application/file_explorer_providers.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/git/application/diff_tab_actions.dart';
import 'package:karmashala/src/features/git/presentation/changes_view.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_session/delivery.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';

/// **Changes reads the one selection.** The worktree switcher above the panel
/// moves it, and Changes, Repository and Files follow together; Changes keeps
/// no worktree of its own that Files would not see.
void main() {
  late FakeDataServer server;
  late DataClient client;
  const homePath = r'C:\src\demo\app';
  const pathA = r'C:\src\demo\wt\agent-a';
  const longBranch = 'agents/loop-73-worktree-navigation-and-a-long-name';

  EnvironmentPath at(String path) =>
      EnvironmentPath(environmentId: 'windows', path: path);

  FileChange change(String path) => FileChange(
    path: path,
    type: FileChangeType.modified,
    staged: false,
    unstaged: true,
  );

  final changesByPath = {
    homePath: [change('lib/main.dart')],
    pathA: [change('lib/from_a.dart')],
  };

  setUp(() async {
    server = FakeDataServer();
    server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
    server.projectRows.insert(project());
    server.repositoryRows
      ..insert(repository(id: 'r1', name: 'app', path: homePath))
      ..insert(repository(id: 'r2', name: 'agent-a', path: pathA));
    client = await server.connect();
  });

  ProviderContainer container() {
    final container = ProviderContainer(
      overrides: [
        // No workbench here, so no diff tab: the real provider would build
        // the terminal controller and leave its autosave timer pending.
        activeDiffFileProvider.overrideWithValue(null),
        dataClientProvider.overrideWithValue(client),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
        ),
        repoWorktreesProvider.overrideWith(
          (ref) async => [
            GitWorktree(path: at(homePath), branch: 'main'),
            GitWorktree(path: at(pathA), branch: longBranch),
          ],
        ),
        recentCommitsProvider.overrideWith((ref) async => const <GitCommit>[]),
        repositoryDeliveryProvider.overrideWith(
          (ref, _) async => SessionDelivery.unknown,
        ),
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

  testWidgets('the Changes header has no worktree picker of its own', (
    tester,
  ) async {
    await pump(tester);

    expect(
      find.byTooltip(
        "Choose which worktree's changes to read. "
        "The session's checkout does not move.",
      ),
      findsNothing,
    );
  });

  testWidgets('a pick moves the Changes list and the Files root together', (
    tester,
  ) async {
    final scope = await pump(tester);
    expect(find.text('main.dart'), findsOneWidget);

    final picked = await scope
        .read(checkoutPickerProvider)
        .selectWorktree('p1', at(pathA));
    await tester.pumpAndSettle();

    expect(picked?.id, 'r2');
    expect(find.text('from_a.dart'), findsOneWidget);
    expect(find.text('main.dart'), findsNothing);
    expect(scope.read(viewedCheckoutProvider)?.path, pathA);
    expect(scope.read(fileTreeRootProvider)?.path, pathA);
    // Unmounted before the container goes: the commit box writes its draft.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the Changes header survives the window matrix on a worktree', (
    tester,
  ) async {
    final scope = container();
    scope.read(selectedRepositoryIdProvider.notifier).select('r2');

    await expectSurvivesWindowMatrix(
      tester,
      build: () => pane(scope),
      because: 'the header carries a long branch and a file count in 240px',
    );
    await tester.pumpWidget(const SizedBox());
  });
}
