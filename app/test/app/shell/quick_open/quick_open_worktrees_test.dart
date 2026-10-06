import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/quick_open/quick_open.dart';
import 'package:karmashala/src/features/explorer/application/checkout_picker.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala_git/git.dart';

import '../../../features/terminal/fake_instance.dart';
import '../../../support/fake_data_server.dart';
import '../../../support/fixtures.dart';
import '../../../support/test_machine.dart';

/// Quick open's "Switch worktree…": the selected checkout's worktrees in the
/// switcher's order and search, and the pick that moves the panel.
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late Override data;

  EnvironmentPath at(String path) =>
      EnvironmentPath(environmentId: 'windows', path: path);
  const root = r'C:\src\demo';
  String wt(int n) =>
      r'C:\src\.demo-worktrees\wt-'
      '$n';
  String branchOf(int n) => 'feature/task-$n';

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    data = await server.override();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project(id: 'p1', name: 'Demo', path: root));
    server.installationRows.insert(agentInstallation());
    server.repositoryRows.insert(
      repository(id: 'main', name: 'demo', path: root),
    );
    for (var n = 1; n <= 5; n++) {
      server.repositoryRows.insert(
        repository(id: 'wt$n', name: 'wt-$n', path: wt(n)),
      );
    }
  });

  Future<ProviderContainer> open(
    WidgetTester tester, {
    bool selected = true,
  }) async {
    final container = ProviderContainer(
      overrides: [
        data,
        ...fakeTerminalOverrides(machine: db),
        repoWorktreesProvider.overrideWith(
          (ref) async => [
            GitWorktree(path: at(root), branch: 'main'),
            for (var n = 1; n <= 5; n++)
              GitWorktree(path: at(wt(n)), branch: branchOf(n)),
          ],
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => QuickOpen.show(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    container.read(selectedProjectIdProvider.notifier).select('p1');
    if (selected) {
      container.read(selectedRepositoryIdProvider.notifier).select('wt2');
    }
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> type(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.pumpAndSettle();
  }

  testWidgets('lists the worktrees, current first, and picks one', (
    tester,
  ) async {
    final container = await open(tester);

    await type(tester, 'switch worktree');
    expect(find.text('Switch worktree…'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    // The palette stays open one level down, on the worktrees.
    expect(find.text('WORKTREES'), findsOneWidget);
    final titles = [
      for (final text in tester.widgetList<Text>(find.byType(Text)))
        if (text.data case final data?
            when data == 'main' || data.startsWith('feature/'))
          data,
    ];
    expect(titles.first, branchOf(2));
    expect(titles, containsAll(['main', branchOf(1), branchOf(5)]));

    await type(tester, 'task 4');
    expect(find.text(branchOf(4)), findsOneWidget);
    expect(find.text(branchOf(1)), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(container.read(selectedCheckoutProvider)?.id, 'wt4');
    expect(find.text('WORKTREES'), findsNothing, reason: 'the palette closed');
  });

  testWidgets('is not offered with no checkout selected', (tester) async {
    await open(tester, selected: false);

    await type(tester, 'switch worktree');

    expect(find.text('Switch worktree…'), findsNothing);
  });
}
