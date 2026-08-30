import 'dart:io';

import 'package:chitragupta/src/app/shell/quick_open/repo_file_index.dart';
import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/core/process/command_runner_providers.dart';
import 'package:chitragupta/src/core/util/directory_change_watcher.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:chitragupta/src/features/git/application/changes_providers.dart';
import 'package:chitragupta/src/features/git/application/changes_service.dart';
import 'package:chitragupta/src/features/git/domain/file_change.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late FakeCommandRunner runner;
  late ChangesService service;

  const repo = EnvironmentPath(environmentId: 'windows', path: r'C:\app');

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    runner = FakeCommandRunner(
      responder: (req) {
        if (req.arguments.contains('status')) {
          return const CommandResult(
            exitCode: 0,
            stdout: ' M a.dart\n?? b.dart\n',
            stderr: '',
          );
        }
        return const CommandResult(
          exitCode: 0,
          stdout: '@@ -1 +1 @@\n-old\n+new\n',
          stderr: '',
        );
      },
    );
    service = ChangesService(
      runnerFactory: FakeCommandRunnerFactory(fallback: runner),
      environmentDao: ExecutionEnvironmentDao(db),
    );
  });
  tearDown(() => db.close());

  test('changes runs git status and parses results', () async {
    final changes = await service.changes(repo);
    expect(changes.map((c) => c.path), ['a.dart', 'b.dart']);
    expect(changes[1].type, FileChangeType.untracked);
    expect(runner.requests.first.arguments, [
      '-C',
      r'C:\app',
      'status',
      '--porcelain=v1',
    ]);
  });

  test('diff runs git diff scoped to the file', () async {
    final diff = await service.diff(repo, path: 'a.dart');
    expect(diff, contains('+new'));
    expect(runner.requests.single.arguments, [
      '-C',
      r'C:\app',
      'diff',
      '--',
      'a.dart',
    ]);
  });

  test('a merge announces the working tree it rewrote', () async {
    final changed = <EnvironmentPath>[];
    final notifying = ChangesService(
      runnerFactory: FakeCommandRunnerFactory(fallback: runner),
      environmentDao: ExecutionEnvironmentDao(db),
      onWorkingTreeChanged: changed.add,
    );
    await notifying.mergeBranch(repo, 'session/s1');
    expect(changed.single, repo);
  });

  test('the app wires a merge through to quick open\'s index', () async {
    // B6: a merge rewrites files in place, and the index's only other notice of
    // that is an OS watcher that exists on some platforms and watches at most
    // eight roots.
    // No real watcher: the point is that the *merge* reports the change, and a
    // filesystem watch firing on its own would make the assertion vacuous.
    final index = RepoFileIndex(
      watcher: DirectoryChangeWatcher(recursiveWatchSupported: false),
    );
    addTearDown(index.dispose);
    final touched = <String>[];
    final subscription = index.changes.listen(touched.add);
    addTearDown(subscription.cancel);
    // `touch` is a no-op on a root nothing has indexed, so the root has to be
    // known before the merge for this to prove anything. An empty temp folder,
    // because a walk of anything real is a slow non-hermetic dependency.
    final root = Directory.systemTemp.createTempSync('chitragupta-merge').path;
    addTearDown(() => Directory(root).deleteSync(recursive: true));
    await index.index(root);
    await pumpEventQueue();
    touched.clear();

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: runner),
        ),
        repoFileIndexProvider.overrideWithValue(index),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(changesServiceProvider)
        .mergeBranch(
          EnvironmentPath(environmentId: 'windows', path: root),
          'session/s1',
        );
    await pumpEventQueue();

    expect(touched, [root]);
  });
}
