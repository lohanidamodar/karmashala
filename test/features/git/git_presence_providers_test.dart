import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';

/// **What a folder that is not a git repository costs, counted in processes.**
///
/// Counted rather than timed: at `--concurrency=4` a wall-clock assertion over
/// a few hundred milliseconds is a coin toss, while spawns are exact.
///
/// | to reach "not a git repository" | before | after |
/// | ------------------------------- | -----: | ----: |
/// | filesystem can see the folder   |     11 |     0 |
/// | filesystem could not (WSL, SSH) |     11 |     1 |
///
/// Eleven, not one, because Riverpod 3 retries a failed provider ten times, and
/// a retrying element carries its error *inside* an `AsyncLoading` — the
/// spinner for the whole 38 s of backoff, which is the "stays loading for a
/// long time" half of the report.
///
/// The second row is the backstop: the probe may answer `unknown` whenever it
/// is unsure, so the states must be reachable from git's own refusal too.
void main() {
  late AppDatabase db;
  late FakeCommandRunner git;

  const checkout = r'C:\Users\me\notes';

  /// git in a folder that is not a repository. 132 ms on the owner's machine —
  /// git is not what was slow, the spawn in front of it was.
  CommandResult notARepository(CommandRequest request) => const CommandResult(
    exitCode: 128,
    stdout: '',
    stderr:
        'fatal: not a git repository (or any of the parent directories): .git',
  );

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository(path: checkout));
    git = FakeCommandRunner(responder: notARepository);
  });
  tearDown(() => db.close());

  /// A container with a repository selected and one fake filesystem behind the
  /// probe.
  ProviderContainer containerWith(GitFiles files) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: git),
        ),
        gitFilesProvider.overrideWithValue(files),
      ],
    );
    addTearDown(container.dispose);
    container.read(selectedRepositoryIdProvider.notifier).select('r1');
    return container;
  }

  /// An ordinary folder on a filesystem that answers: no `.git` anywhere above
  /// it, and the folder itself readable, which is the proof the reader needs
  /// before it will conclude anything.
  final plainFolder = _StatFiles({checkout: PathEntry.directory});

  /// A checkout inside a real clone. The `.git` is two levels up, which is
  /// where git would find it too.
  final insideAClone = _StatFiles({
    r'C:\Users\me\.git': PathEntry.directory,
    checkout: PathEntry.directory,
  });

  /// A filesystem this process cannot see at all — a stopped WSL distribution,
  /// an SSH host. Every reading is `unknown`, so every provider asks git.
  const unreadable = _StatFiles({});

  group('the four panes\' providers', () {
    test('a folder that is not a repository spawns nothing at all', () async {
      final container = containerWith(plainFolder);

      await expectLater(
        container.read(repositoryChangesProvider.future),
        throwsA(isA<NotAGitRepository>()),
      );

      expect(
        git.requests,
        isEmpty,
        reason: 'the verdict came off the filesystem; git was never asked',
      );
    });

    test('every one of the four reaches it, and none of them spawns', () async {
      final container = containerWith(plainFolder);

      // Each already had a null or an empty list meaning something else — "no
      // remote", "detached", "no other worktrees", "no changes".
      for (final read in [
        () => container.read(repositoryChangesProvider.future),
        () => container.read(currentBranchProvider.future),
        () => container.read(repoRemoteUrlProvider.future),
        () => container.read(recentCommitsProvider.future),
        () => container.read(repoWorktreesProvider.future),
      ]) {
        await expectLater(read(), throwsA(isA<NotAGitRepository>()));
      }

      expect(git.requests, isEmpty);
    });

    test('a subfolder of a clone is a repository, and git is asked', () async {
      // The trap: git searches parent directories, so a folder with no `.git`
      // of its own is still in a repository.
      git.responder = (_) =>
          const CommandResult(exitCode: 0, stdout: ' M a.dart\n', stderr: '');
      final container = containerWith(insideAClone);

      expect(
        (await container.read(repositoryChangesProvider.future)).single.path,
        'a.dart',
      );
      expect(git.requests, hasLength(1));
    });

    test('a filesystem that could not answer still asks git — once', () async {
      final container = containerWith(unreadable);

      // Unknown is not a verdict, so the process is spent exactly as it was
      // before this existed…
      await expectLater(
        container.read(repositoryChangesProvider.future),
        throwsA(isA<GitException>()),
      );
      expect(git.requests, hasLength(1));

      // …and git's own refusal reaches the same calm state the probe would
      // have, so a pane words the folder identically either way.
      expect(
        gitTroubleOf(
          container.read(repositoryChangesProvider).error!,
        ),
        GitTrouble.notARepository,
      );
    });
  });

  group('a settled verdict is not asked eleven times', () {
    // Riverpod's retry runs on a `Timer`, which `testWidgets` fakes — so this
    // advances a clock it controls and then counts spawns. Nothing here asserts
    // a duration.
    Future<int> gitCallsWhileWaiting(
      WidgetTester tester,
      GitFiles files,
    ) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: containerWith(files),
          child: const MaterialApp(home: _WatchesTheChanges()),
        ),
      );
      // Well past `defaultRetry`'s ten attempts, whose backoff sums to 38.2 s.
      await tester.pump(const Duration(minutes: 2));
      return git.requests.length;
    }

    testWidgets('the filesystem\'s verdict costs no processes ever', (
      tester,
    ) async {
      expect(await gitCallsWhileWaiting(tester, plainFolder), 0);
    });

    testWidgets('git\'s own refusal costs one, not eleven', (tester) async {
      expect(await gitCallsWhileWaiting(tester, unreadable), 1);
    });

    testWidgets('a real failure still gets its retries', (tester) async {
      // The control: a zero above must not be bought by switching retry off
      // everywhere.
      git.responder = (_) => const CommandResult(
        exitCode: 128,
        stdout: '',
        stderr:
            r"fatal: Unable to create 'C:/src/app/.git/index.lock': File exists.",
      );
      expect(
        await gitCallsWhileWaiting(tester, unreadable),
        greaterThan(1),
      );
    });
  });

  group('the Repository pane reads one verdict for its whole GIT section', () {
    test('the probe decides it, with no git of any kind', () async {
      final container = containerWith(plainFolder);
      // The probe is a future; nothing is claimed until it answers (§19).
      expect(container.read(selectedCheckoutGitTroubleProvider), isNull);

      await container.read(checkoutGitPresenceProvider(
        repository(path: checkout).path,
      ).future);

      expect(
        container.read(selectedCheckoutGitTroubleProvider)?.trouble,
        GitTrouble.notARepository,
      );
      expect(git.requests, isEmpty);
    });

    test('a git that could not be reached is not a folder without git', () async {
      git.throwError = CommandException('Failed to run "git" in WSL "Ubuntu"');
      final container = containerWith(unreadable);
      await expectLater(
        container.read(repoWorktreesProvider.future),
        throwsA(isA<CommandException>()),
      );

      final report = container.read(selectedCheckoutGitTroubleProvider);
      expect(report?.trouble, GitTrouble.unreachable);
      expect(report?.message, gitUnreachableMessage);
    });

    testWidgets('a real failure keeps git\'s own words', (tester) async {
      git.responder = (_) => const CommandResult(
        exitCode: 128,
        stdout: '',
        stderr: 'fatal: detected dubious ownership in repository',
      );
      final container = containerWith(unreadable);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: _WatchesTheWorktrees()),
        ),
      );

      // Past the retries — this is the one case that retries at all, and the
      // verdict has to survive them.
      await tester.pump(const Duration(minutes: 2));

      final report = container.read(selectedCheckoutGitTroubleProvider);
      expect(report?.trouble, GitTrouble.failed);
      expect(report?.message, contains('dubious ownership'));
    });
  });
}

/// The smallest widget that keeps `repositoryChangesProvider` alive, so the
/// retry timer above has something to retry for. It draws nothing: what is
/// being counted is spawns, not pixels.
class _WatchesTheChanges extends ConsumerWidget {
  const _WatchesTheChanges();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(repositoryChangesProvider);
    return const SizedBox.shrink();
  }
}

/// The same, for the provider the Repository pane's one verdict is read off.
class _WatchesTheWorktrees extends ConsumerWidget {
  const _WatchesTheWorktrees();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(repoWorktreesProvider);
    return const SizedBox.shrink();
  }
}

/// A filesystem that only answers `stat`. Anything not in the table is
/// [PathEntry.none] — which is both "not there" and "the share did not answer",
/// exactly as `HostGitFiles` reports them.
class _StatFiles implements GitFiles {
  const _StatFiles(this.entries);

  final Map<String, PathEntry> entries;

  @override
  Future<PathEntry> typeOf(String path) async =>
      entries[path] ?? PathEntry.none;

  @override
  Future<String?> readString(String path) async => null;

  @override
  Future<bool> exists(String path) async => false;

  @override
  Future<void> createDirectory(String path) async {}

  @override
  Future<void> writeString(String path, String contents) async {}
}
