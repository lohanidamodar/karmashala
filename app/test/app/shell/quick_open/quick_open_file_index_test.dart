import 'package:karmashala/src/app/shell/quick_open/quick_open.dart';
import 'package:karmashala/src/app/shell/quick_open/repo_file_index.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_files/values.dart';

import '../../../features/terminal/fake_instance.dart';
import '../../../support/fakes.dart';
import '../../../support/fixtures.dart';
import '../../../support/fake_data_server.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import '../../../support/test_machine.dart';
import 'package:agent_cli/process.dart';

/// The dialog's side of the file index (slice 3c): the server walks the
/// checkout and answers `files.index`; the palette draws what it answered,
/// asks again when the tree is said to have moved, and asks for the checkout
/// that is selected now. The walk itself is tested at the server
/// (`packages/karmashala_files/test/repo_file_index_test.dart`).
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late Override data;
  const root = EnvironmentPath(environmentId: 'windows', path: '/src/app');

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    data = await server.override();
    server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
    server.projectRows.insert(project(name: 'Karmashala'));
    server.repositoryRows.insert(repository(name: 'app'));
    server.installationRows.insert(agentInstallation());
    db.server.sessionRows.insert(
      session(id: 's1', title: 'Fix login redirect'),
    );
  });

  void serverHas(EnvironmentPath at, List<String> files) =>
      server.filesWork.indexes[at] = RepoFiles(files: files, separator: '/');

  Future<ProviderContainer> open(
    WidgetTester tester, {
    EnvironmentPath Function()? rootOf,
  }) async {
    final container = ProviderContainer(
      overrides: [
        data,
        ...fakeTerminalOverrides(machine: db),
        quickOpenFileRootProvider.overrideWith(
          (ref) => (rootOf ?? () => root)(),
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
    container.read(selectedRepositoryIdProvider.notifier).select('r1');
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pumpAndSettle();
  }

  testWidgets('typing finds the repository\'s files, as the server answered '
      'them', (tester) async {
    serverHas(root, ['lib/alpha_widget.dart', 'README.md']);
    await open(tester);

    await type(tester, 'alpha');

    expect(find.text('alpha_widget.dart'), findsOneWidget);
    expect(find.text('FILES'), findsOneWidget);
    expect(server.filesWork.kinds, ['files.index']);
  });

  testWidgets('a tree touched behind the open palette is asked again: a new '
      'file offered, a deleted one not', (tester) async {
    serverHas(root, ['lib/alpha_widget.dart', 'lib/alpha_doomed.dart']);
    final container = await open(tester);
    await type(tester, 'alpha');
    expect(find.text('alpha_doomed.dart'), findsOneWidget);

    // An agent wrote and deleted while Quick Open was up; the server says
    // the checkout moved.
    serverHas(root, ['lib/alpha_widget.dart', 'lib/alpha_written_later.dart']);
    container.read(repoFileIndexProvider).touch(root);
    await tester.pumpAndSettle();

    expect(server.filesWork.kinds, ['files.index', 'files.index']);
    expect(find.text('alpha_written_later.dart'), findsOneWidget);
    expect(find.text('alpha_doomed.dart'), findsNothing);
    expect(find.text('alpha_widget.dart'), findsOneWidget);
  });

  testWidgets('a repository with no matching files says nothing matches', (
    tester,
  ) async {
    serverHas(root, ['lib/unrelated.dart']);
    await open(tester);

    await type(tester, 'zzzqqq');

    expect(find.text('Nothing matches.'), findsOneWidget);
  });

  testWidgets('switching repository asks for the one selected now', (
    tester,
  ) async {
    const other = EnvironmentPath(environmentId: 'ssh:box', path: '/srv/other');
    serverHas(root, ['a.dart']);
    serverHas(other, ['alpha_elsewhere.dart']);
    var selected = root;
    final container = await open(tester, rootOf: () => selected);
    await type(tester, 'alpha');

    selected = other;
    container.invalidate(quickOpenFileRootProvider);
    await type(tester, 'alphab');
    await type(tester, 'alpha');

    expect(
      [for (final r in server.filesWork.asked.whereType<FilesIndex>()) r.root],
      [root, other],
    );
    expect(find.text('alpha_elsewhere.dart'), findsWidgets);
  });
}
