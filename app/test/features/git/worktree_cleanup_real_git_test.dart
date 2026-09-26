import 'dart:io';

import 'package:karmashala/src/features/environments/application/environment_resolver.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/application/worktree_cleanup_policy.dart';
import 'package:karmashala/src/features/git/application/worktree_cleanup_service.dart';
import 'package:karmashala_git/worktrees.dart';
import 'package:karmashala/src/features/git/data/worktree_cleanup_store.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/temp_directory.dart';

/// Automatic worktree cleanup against **real git in a temporary repository**:
/// each refusal is proven by a worktree a rule matches and that is still on
/// disk afterwards, and each removal by a directory that is gone while its
/// branch is not. Nothing here touches a worktree the test did not make.
void main() {
  final hasGit = Process.runSync('git', ['--version']).exitCode == 0;

  late Directory tmp;
  late String root;
  late String main;
  late AppDatabase db;
  late String envId;
  late MovableClock clock;
  late WorktreeService worktrees;
  late List<Session> sessions;
  late Set<String> live;
  late List<WorktreeCleanupLogEntry> logged;
  late List<List<String>> archived;
  late GitPresence presence;

  const mergedOnly = WorktreeCleanupSettings(
    enabled: true,
    rules: WorktreeCleanupRules(inactiveEnabled: false, merged: true),
  );

  void git(String dir, List<String> args) {
    final result = Process.runSync('git', [
      '-C',
      dir,
      '-c',
      'user.name=t',
      '-c',
      'user.email=t@t',
      '-c',
      'commit.gpgsign=false',
      ...args,
    ]);
    if (result.exitCode != 0) fail('git $args: ${result.stderr}');
  }

  bool branchExists(String branch) =>
      Process.runSync('git', [
        '-C',
        main,
        'rev-parse',
        '--verify',
        '--quiet',
        'refs/heads/$branch',
      ]).exitCode ==
      0;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('karmashala_cleanup_');
    root = tmp.resolveSymbolicLinksSync();
    main = p.join(root, 'app');
    Directory(main).createSync();
    File(p.join(main, 'README.md')).writeAsStringSync('app\n');
    File(
      p.join(main, '.gitignore'),
    ).writeAsStringSync('build/\nnode_modules/\n');
    git(main, ['init', '-q', '-b', 'main']);
    git(main, ['config', 'core.autocrlf', 'false']);
    git(main, ['add', '-A']);
    git(main, ['commit', '-q', '-m', 'init']);

    db = AppDatabase.memory();
    // Well past the one-day grace, unless a case winds it back.
    clock = MovableClock(DateTime.now().toUtc().add(const Duration(days: 3)));
    envId = ensureLocalEnvironment(ExecutionEnvironmentDao(db), clock);
    worktrees = WorktreeService(
      runnerFactory: const CommandRunnerFactory(),
      environmentOf: worktreeEnvironmentOf(ExecutionEnvironmentDao(db)),
    );
    sessions = [];
    live = {};
    logged = [];
    archived = [];
    presence = GitPresence.repository;
  });

  tearDown(() {
    db.close();
    removeTempDirectory(tmp);
  });

  EnvironmentPath at(String path) =>
      EnvironmentPath(environmentId: envId, path: path);

  /// A worktree on a new [branch], by default where Karmashala puts one.
  String addWorktree(String branch, {String? dir}) {
    final path = dir ?? p.join(root, kKarmashalaWorktreesFolder, 'app-$branch');
    git(main, ['worktree', 'add', '-q', '-b', branch, path]);
    return path;
  }

  void commitIn(String dir, String name) {
    File(p.join(dir, '$name.txt')).writeAsStringSync('$name\n');
    git(dir, ['add', '-A']);
    git(dir, ['commit', '-q', '-m', name]);
  }

  /// A branch with one commit, fast-forwarded into `main`.
  String mergedWorktree(String branch) {
    final dir = addWorktree(branch);
    commitIn(dir, branch);
    git(main, ['merge', '-q', '--ff-only', branch]);
    return dir;
  }

  WorktreeCleanupService service({List<Session> Function()? sessionsOf}) =>
      WorktreeCleanupService(
        projects: () => [project(environmentId: envId, path: root)],
        repositoriesOf: (_) => [repository(environmentId: envId, path: main)],
        presenceOf: (_) async => presence,
        familyKeyOf: (_) async => null,
        environmentKind: (_) => EnvironmentKind.windowsNative,
        gitFor: worktrees.gitFor,
        removeIfClean: worktrees.removeIfClean,
        sessions: sessionsOf ?? () => sessions,
        isLive: (s) => live.contains(s.id),
        liveTerminalDirectories: () => const [],
        lastEventAt: (_) => null,
        createdAt: (_) => null,
        clock: clock,
        onRemoved: (entry, ids) {
          logged.add(entry);
          archived.add(ids);
        },
      );

  WorktreeCleanupVerdict only(WorktreeCleanupReport report) {
    expect(report.verdicts, hasLength(1), reason: '${report.notes}');
    return report.verdicts.single;
  }

  group('with real git', () {
    test('off by default: nothing is removed, though a preview shows what '
        'turning it on would do', () async {
      final dir = mergedWorktree('done');

      final swept = await service().sweep(
        const WorktreeCleanupSettings(),
        automatic: true,
      );
      expect(swept.verdicts, isEmpty);
      expect(Directory(dir).existsSync(), isTrue);

      final preview = await service().preview(
        const WorktreeCleanupSettings(
          rules: WorktreeCleanupRules(inactiveEnabled: false),
        ),
      );
      expect(only(preview).outcome, WorktreeCleanupOutcome.wouldRemove);
      expect(only(preview).matched, [WorktreeCleanupRule.merged]);
      expect(Directory(dir).existsSync(), isTrue, reason: 'a preview removes');
      expect(logged, isEmpty);
    });

    test('a merged worktree is removed, its branch kept, and the removal '
        'logged with the rule', () async {
      final dir = mergedWorktree('done');
      sessions = [
        session(id: 'old', worktree: at(dir), status: SessionStatus.completed),
      ];

      final report = await service().sweep(mergedOnly, automatic: true);

      expect(only(report).outcome, WorktreeCleanupOutcome.removed);
      expect(Directory(dir).existsSync(), isFalse);
      expect(
        branchExists('done'),
        isTrue,
        reason: 'the branch is never deleted',
      );
      final listed = await worktrees.list(at(main));
      expect(listed, hasLength(1), reason: 'git no longer lists it');
      expect(logged.single.removed, isTrue);
      expect(logged.single.rules, [WorktreeCleanupRule.merged]);
      expect(logged.single.automatic, isTrue);
      expect(archived.single, ['old']);
    });

    test('uncommitted changes keep a worktree a rule matches', () async {
      final dir = mergedWorktree('dirty');
      File(p.join(dir, 'notes.txt')).writeAsStringSync('unsaved\n');
      File(p.join(dir, 'README.md')).writeAsStringSync('edited\n');

      final report = await service().sweep(mergedOnly, automatic: true);

      final verdict = only(report);
      expect(verdict.outcome, WorktreeCleanupOutcome.kept);
      expect(verdict.matched, [WorktreeCleanupRule.merged]);
      expect(
        verdict.refusals.map((r) => r.kind),
        contains(WorktreeRefusalKind.uncommittedChanges),
      );
      expect(File(p.join(dir, 'notes.txt')).existsSync(), isTrue);
      expect(logged, isEmpty);
    });

    test('an active session keeps it, and git is not even asked', () async {
      final dir = mergedWorktree('busy');
      sessions = [session(id: 'run', title: 'Busy', worktree: at(dir))];
      live = {'run'};

      final verdict = only(await service().sweep(mergedOnly, automatic: true));

      expect(verdict.outcome, WorktreeCleanupOutcome.kept);
      expect(verdict.refusals.single.kind, WorktreeRefusalKind.activeSession);
      expect(verdict.refusals.single.detail, contains('"Busy"'));
      expect(verdict.facts.contents, isNull);
      expect(Directory(dir).existsSync(), isTrue);
    });

    test('a worktree shared by two sessions is kept', () async {
      final dir = mergedWorktree('shared');
      sessions = [
        session(id: 'a', worktree: at(dir), status: SessionStatus.completed),
        session(
          id: 'b',
          workingDirectory: at(p.join(dir, 'lib')),
          status: SessionStatus.completed,
        ),
      ];

      final verdict = only(await service().sweep(mergedOnly, automatic: true));

      expect(verdict.outcome, WorktreeCleanupOutcome.kept);
      expect(verdict.refusals.single.kind, WorktreeRefusalKind.shared);
      expect(Directory(dir).existsSync(), isTrue);
    });

    test('a session that starts after the scan, before the removal, keeps '
        'it', () async {
      final dir = mergedWorktree('late');
      final starting = session(id: 'new', title: 'Late', worktree: at(dir));
      var asked = 0;
      live = {'new'};

      final verdict = only(
        await service(
          // The scan sees an empty table; the re-check just before removal
          // sees the session that has since started.
          sessionsOf: () => ++asked == 1 ? const [] : [starting],
        ).sweep(mergedOnly, automatic: true),
      );

      expect(asked, 2, reason: 'the session table is read again at removal');
      expect(verdict.outcome, WorktreeCleanupOutcome.kept);
      expect(verdict.recheckedBeforeRemoval, isTrue);
      expect(verdict.refusals.single.kind, WorktreeRefusalKind.activeSession);
      expect(Directory(dir).existsSync(), isTrue);
      expect(logged, isEmpty);
    });

    test('a file written after the scan, before the removal, keeps it — the '
        'status is read again', () async {
      final dir = mergedWorktree('racing');
      var asked = 0;

      final verdict = only(
        await service(
          sessionsOf: () {
            if (++asked == 2) {
              File(p.join(dir, 'just-now.txt')).writeAsStringSync('x\n');
            }
            return const [];
          },
        ).sweep(mergedOnly, automatic: true),
      );

      expect(verdict.outcome, WorktreeCleanupOutcome.kept);
      expect(verdict.recheckedBeforeRemoval, isTrue);
      expect(
        verdict.refusals.single.kind,
        WorktreeRefusalKind.uncommittedChanges,
      );
      expect(File(p.join(dir, 'just-now.txt')).existsSync(), isTrue);
    });

    test(
      'ignored build output keeps a worktree; node_modules does not',
      () async {
        final built = mergedWorktree('built');
        Directory(p.join(built, 'build')).createSync();
        File(p.join(built, 'build', 'app.exe')).writeAsStringSync('bin');
        final deps = mergedWorktree('deps');
        Directory(
          p.join(deps, 'node_modules', 'x'),
        ).createSync(recursive: true);
        File(p.join(deps, 'node_modules', 'x', 'i.js')).writeAsStringSync('');

        final report = await service().sweep(mergedOnly, automatic: true);
        final byLabel = {for (final v in report.verdicts) v.facts.label: v};

        expect(byLabel['built']!.outcome, WorktreeCleanupOutcome.kept);
        expect(
          byLabel['built']!.refusals.single.kind,
          WorktreeRefusalKind.ignoredFiles,
        );
        expect(File(p.join(built, 'build', 'app.exe')).existsSync(), isTrue);
        expect(byLabel['deps']!.outcome, WorktreeCleanupOutcome.removed);
        expect(Directory(deps).existsSync(), isFalse);
      },
    );

    test('a squash-merged branch does not read as merged, and the preview '
        'says why', () async {
      final dir = addWorktree('squashed');
      commitIn(dir, 'squashed');
      git(main, ['merge', '-q', '--squash', 'squashed']);
      git(main, ['commit', '-q', '-m', 'squashed as one']);

      final verdict = only(await service().preview(mergedOnly));

      expect(verdict.outcome, WorktreeCleanupOutcome.kept);
      expect(verdict.matched, isEmpty);
      expect(verdict.unmatched.join(' '), contains('squash'));
      expect(Directory(dir).existsSync(), isTrue);
    });

    test('a worktree someone made by hand is never removed', () async {
      final dir = addWorktree('manual', dir: p.join(root, 'manual-wt'));
      commitIn(dir, 'manual');
      git(main, ['merge', '-q', '--ff-only', 'manual']);

      final verdict = only(await service().sweep(mergedOnly, automatic: true));

      expect(verdict.outcome, WorktreeCleanupOutcome.kept);
      expect(verdict.refusals.single.kind, WorktreeRefusalKind.notMadeHere);
      expect(Directory(dir).existsSync(), isTrue);
    });

    test('"no commits" spares a worktree made today, and takes it once it '
        'has sat a day', () async {
      clock.now = DateTime.now().toUtc();
      final dir = addWorktree('fresh');
      const settings = WorktreeCleanupSettings(
        enabled: true,
        rules: WorktreeCleanupRules(
          inactiveEnabled: false,
          merged: false,
          noCommitsBeyondDefault: true,
        ),
      );

      final today = only(await service().sweep(settings, automatic: true));
      expect(today.outcome, WorktreeCleanupOutcome.kept);
      expect(today.refusals.single.kind, WorktreeRefusalKind.recentlyActive);
      expect(Directory(dir).existsSync(), isTrue);

      clock.advance(const Duration(days: 2));
      final later = only(await service().sweep(settings, automatic: true));
      expect(later.outcome, WorktreeCleanupOutcome.removed);
      expect(later.matched, [WorktreeCleanupRule.noCommitsBeyondDefault]);
      expect(Directory(dir).existsSync(), isFalse);
    });

    test(
      '"merged" alone does not take a worktree nothing was committed in',
      () async {
        final dir = addWorktree('untouched');

        final verdict = only(
          await service().sweep(mergedOnly, automatic: true),
        );

        expect(verdict.outcome, WorktreeCleanupOutcome.kept);
        expect(
          verdict.unmatched.join(' '),
          contains('nothing was ever committed'),
        );
        expect(Directory(dir).existsSync(), isTrue);
      },
    );

    test(
      '"inactive" measures the HEAD reflog, and only past its threshold',
      () async {
        final dir = addWorktree('idle');
        commitIn(dir, 'idle');
        const settings = WorktreeCleanupSettings(
          enabled: true,
          rules: WorktreeCleanupRules(inactiveDays: 14, merged: false),
        );

        final soon = only(await service().sweep(settings, automatic: true));
        expect(soon.outcome, WorktreeCleanupOutcome.kept);
        expect(soon.facts.activitySource, 'HEAD last moved');
        expect(Directory(dir).existsSync(), isTrue);

        clock.advance(const Duration(days: 20));
        final late = only(await service().sweep(settings, automatic: true));
        expect(late.outcome, WorktreeCleanupOutcome.removed);
        expect(late.matched, [WorktreeCleanupRule.inactive]);
        expect(branchExists('idle'), isTrue);
      },
    );

    test(
      'a project turned off is left alone even with the default on',
      () async {
        final dir = mergedWorktree('optout');
        final settings = mergedOnly.copyWith(
          projects: {
            'p1': const ProjectCleanupPolicy(mode: WorktreeCleanupMode.off),
          },
        );

        expect(
          (await service().sweep(settings, automatic: true)).verdicts,
          isEmpty,
        );
        expect((await service().preview(settings)).verdicts, isEmpty);
        expect(Directory(dir).existsSync(), isTrue);
      },
    );

    test(
      'a project that is not a Git repository is skipped without a word',
      () async {
        mergedWorktree('ignored');
        presence = GitPresence.notARepository;

        final report = await service().sweep(mergedOnly, automatic: true);

        expect(report.verdicts, isEmpty);
        expect(report.notes, isEmpty);
      },
    );
  }, skip: hasGit ? false : 'git is not installed');
}
