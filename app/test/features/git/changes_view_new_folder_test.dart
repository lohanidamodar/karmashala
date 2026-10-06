/// A folder git has never seen, in the Changes pane: a row of its own that
/// opens onto its files, each one staged, discarded and read like any other.
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

  List<GitStage> staged() => [
    for (final request in server.gitWork.asked)
      if (request is GitStage) request,
  ];

  setUp(() async {
    server = FakeDataServer()..environmentRows.upsert(windowsEnv());
    client = await server.connect();
  });

  Future<void> pump(WidgetTester tester, List<FileChange> files) async {
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
          workingTreeStatusProvider.overrideWith(
            (ref) async => const WorkingTreeStatus(branch: 'work'),
          ),
          viewedCheckoutProvider.overrideWithValue(checkout),
        ],
        child: const MaterialApp(
          home: Scaffold(body: ChangesView(repositoryName: 'app')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  FileChange newFile(String path, String folder, {int more = 0}) => FileChange(
    path: path,
    type: FileChangeType.untracked,
    staged: false,
    unstaged: true,
    newFolder: folder,
    moreFiles: more,
  );

  const modified = FileChange(
    path: 'lib/main.dart',
    type: FileChangeType.modified,
    staged: false,
    unstaged: true,
  );

  final feature = [
    newFile('lib/feature/one.dart', 'lib/feature'),
    newFile('lib/feature/deep/two.dart', 'lib/feature'),
  ];

  testWidgets('a new folder is a row of its own, open onto its files', (
    tester,
  ) async {
    await pump(tester, [modified, ...feature]);

    expect(find.text('lib/feature/'), findsOneWidget);
    expect(find.text('one.dart'), findsOneWidget);
    expect(find.text('two.dart'), findsOneWidget);
    expect(find.text('UNSTAGED CHANGES  3'), findsOneWidget);
  });

  testWidgets('the folder row folds its files away and back', (tester) async {
    await pump(tester, [modified, ...feature]);

    await tester.tap(find.text('lib/feature/'));
    await tester.pumpAndSettle();
    expect(find.text('one.dart'), findsNothing);
    expect(find.text('main.dart'), findsOneWidget);

    await tester.tap(find.text('lib/feature/'));
    await tester.pumpAndSettle();
    expect(find.text('one.dart'), findsOneWidget);
  });

  testWidgets('a file in the folder stages alone; the folder stages whole', (
    tester,
  ) async {
    await pump(tester, feature);

    await tester.tap(find.byTooltip('Stage folder'));
    await tester.pumpAndSettle();
    expect(staged().last.paths, ['lib/feature/']);

    // The first per-file Stage is the folder's first file in path order.
    await tester.tap(find.byTooltip('Stage').first);
    await tester.pumpAndSettle();
    expect(staged().last.paths, ['lib/feature/deep/two.dart']);
  });

  testWidgets('files past the limit are one row, and still counted', (
    tester,
  ) async {
    await pump(tester, [
      newFile('gen/a.txt', 'gen'),
      newFile('gen/', 'gen', more: 1500),
    ]);

    expect(find.text('1,500 more files in gen'), findsOneWidget);
    expect(find.text('UNSTAGED CHANGES  1501'), findsOneWidget);
    expect(find.text('1501'), findsOneWidget);
  });
}
