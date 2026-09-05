import 'dart:io';

import 'package:karmashala/src/app/shell/quick_open/repo_file_index.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/directory_change_watcher.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/git/application/changes_service.dart';
import 'package:karmashala/src/features/git/data/git_files.dart';
import 'package:karmashala/src/features/git/domain/file_change.dart';
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
    final root = Directory.systemTemp.createTempSync('karmashala-merge').path;
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

  /// **`origin`'s two facts, read rather than asked — and the fallback.**
  ///
  /// `GitOriginReader` owns the parsing and is tested where it lives. What is
  /// tested here is the seam: that a fact the files answered costs no
  /// subprocess, that a fact they could not answer costs exactly one, and that
  /// the two decisions are made **independently**. Falling back on the pair
  /// would spend a process learning something a file had already said.
  group('originFacts', () {
    /// Every `git` call this service makes, as its subcommand.
    List<String> subcommands() => [
      for (final request in runner.requests)
        request.arguments.skip(2).take(2).join(' '),
    ];

    ChangesService serviceOver(Map<String, String> disk) => ChangesService(
      runnerFactory: FakeCommandRunnerFactory(fallback: runner),
      environmentDao: ExecutionEnvironmentDao(db),
      files: _FakeFiles(disk),
    );

    setUp(() {
      runner = FakeCommandRunner(
        responder: (req) {
          final joined = req.arguments.skip(2).join(' ');
          if (joined.startsWith('remote get-url')) {
            return const CommandResult(
              exitCode: 0,
              stdout: 'https://github.com/acme/asked.git\n',
              stderr: '',
            );
          }
          if (joined.startsWith('rev-parse --abbrev-ref')) {
            return const CommandResult(
              exitCode: 0,
              stdout: 'origin/asked\n',
              stderr: '',
            );
          }
          return const CommandResult(exitCode: 0, stdout: '', stderr: '');
        },
      );
    });

    test('two files answer both, and nothing is spawned', () async {
      final facts = await serviceOver({
        r'C:\app\.git\config':
            '[remote "origin"]\n\turl = https://github.com/acme/read.git\n',
        r'C:\app\.git\refs\remotes\origin\HEAD':
            'ref: refs/remotes/origin/main\n',
      }).originFacts(repo);

      expect(facts.url, 'https://github.com/acme/read.git');
      expect(facts.head, 'origin/main');
      expect(facts.defaultBranch, 'main');
      expect(
        subcommands(),
        isEmpty,
        reason:
            'a subprocess ran for something `.git` had already said; '
            '`CreateProcessW` is charged to the calling thread',
      );
    });

    test('a fact the files cannot answer costs one process, not two', () async {
      // No `refs/remotes/origin/HEAD` and no `packed-refs`, which is what git's
      // `reftable` backend leaves behind — so the head is unknown while the
      // URL is not.
      final facts = await serviceOver({
        r'C:\app\.git\config':
            '[remote "origin"]\n\turl = https://github.com/acme/read.git\n',
      }).originFacts(repo);

      expect(facts.url, 'https://github.com/acme/read.git');
      expect(facts.head, 'origin/asked');
      expect(subcommands(), ['rev-parse --abbrev-ref']);
    });

    test('nothing readable falls back to both processes', () async {
      final facts = await serviceOver(const {}).originFacts(repo);
      expect(facts.url, 'https://github.com/acme/asked.git');
      expect(facts.head, 'origin/asked');
      expect(subcommands(), ['remote get-url', 'rev-parse --abbrev-ref']);
    });

    test('no remote is an answer, and asks git nothing', () async {
      final facts = await serviceOver({
        r'C:\app\.git\config': '[core]\n\tbare = false\n',
      }).originFacts(repo);
      expect(facts.hasRemote, isFalse);
      expect(facts.head, isNull);
      expect(subcommands(), isEmpty);
    });

    test('a repository on an SSH host is never opened locally', () async {
      // There is no local path for it, so the answer is "ask git over the
      // transport" — and a `File` opened on the remote's spelling would be a
      // path on *this* machine, which is the mistake constraint 8 exists for.
      ExecutionEnvironmentDao(db).upsert(sshEnvFixture());
      final files = _FakeFiles(const {});
      final facts = await ChangesService(
        runnerFactory: FakeCommandRunnerFactory(fallback: runner),
        environmentDao: ExecutionEnvironmentDao(db),
        files: files,
      ).originFacts(
        const EnvironmentPath(environmentId: 'ssh:h1', path: '/home/me/app'),
      );

      expect(facts.url, 'https://github.com/acme/asked.git');
      expect(files.reads, isEmpty);
      expect(subcommands(), ['remote get-url', 'rev-parse --abbrev-ref']);
    });
  });
}

/// [GitFiles] over a map, recording what was read. A missing key reads as null,
/// which is what the real one answers for an absent file, an unreadable one and
/// a directory alike.
class _FakeFiles implements GitFiles {
  _FakeFiles(this.contents);

  final Map<String, String> contents;
  final List<String> reads = [];

  @override
  Future<String?> readString(String path) async {
    reads.add(path);
    return contents[path];
  }

  @override
  Future<bool> exists(String path) async => contents.containsKey(path);

  @override
  Future<PathEntry> typeOf(String path) async =>
      contents.containsKey(path) ? PathEntry.file : PathEntry.none;

  @override
  Future<void> createDirectory(String path) async {}

  @override
  Future<void> writeString(String path, String contents) async {}
}
