import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/environments/application/environment_resolver.dart';
import 'package:karmashala/src/features/environments/data/environments_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/git/application/worktree_cleanup_policy.dart';
import 'package:karmashala_git/worktrees.dart';
import 'package:karmashala/src/features/git/data/worktree_cleanup_store.dart';
import 'package:karmashala_git/git.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';

void main() {
  final now = DateTime.utc(2026, 9, 21, 12);
  const wt = EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\src\.karmashala-worktrees\app-x',
  );

  WorktreeFacts facts({
    List<String> live = const [],
    List<String> sessionIds = const [],
    WorktreeContents? contents = const WorktreeContents(),
    String? base = 'origin/main',
    int? ahead = 0,
    bool? madeCommits = true,
    DateTime? lastActivity,
    bool madeHere = true,
  }) => WorktreeFacts(
    projectId: 'p1',
    projectName: 'Demo',
    repo: const EnvironmentPath(environmentId: 'windows', path: r'C:\src\app'),
    path: wt,
    branch: 'x',
    madeByKarmashala: madeHere,
    liveSessions: live,
    sessionIds: sessionIds,
    contents: contents,
    base: base,
    commitsBeyondBase: ahead,
    madeCommits: madeCommits,
    lastActivity: lastActivity ?? now.subtract(const Duration(days: 30)),
  );

  group('settings', () {
    test('are off when nothing was ever stored, or what was is garbage', () {
      for (final json in <Object?>[null, 'x', 7, <String, Object?>{}]) {
        final settings = WorktreeCleanupSettings.fromJson(json);
        expect(settings.enabled, isFalse);
        expect(settings.anyEnabled, isFalse);
        expect(settings.effectiveFor('p1'), isNull);
      }
      // Only a literal true turns it on.
      expect(
        WorktreeCleanupSettings.fromJson({'enabled': 'true'}).enabled,
        isFalse,
      );
    });

    test('a project inherits the default, can opt out, or has its own', () {
      const custom = WorktreeCleanupRules(inactiveDays: 3, merged: false);
      const settings = WorktreeCleanupSettings(
        projects: {
          'off': ProjectCleanupPolicy(mode: WorktreeCleanupMode.off),
          'own': ProjectCleanupPolicy(
            mode: WorktreeCleanupMode.custom,
            rules: custom,
          ),
        },
      );
      // Default off: only the custom project is swept...
      expect(settings.effectiveFor('any'), isNull);
      expect(settings.effectiveFor('own'), custom);
      expect(settings.anyEnabled, isTrue);
      // ...but a preview shows what the default would do.
      expect(settings.previewFor('any'), const WorktreeCleanupRules());
      expect(settings.previewFor('off'), isNull);

      final on = settings.copyWith(enabled: true);
      expect(on.effectiveFor('any'), const WorktreeCleanupRules());
      expect(on.effectiveFor('off'), isNull);
    });

    test('survive a round trip through the preferences, with no migration', () {
      final preferences = FakeDataServer().store;
      final store = WorktreeCleanupStore(preferences);
      expect(store.settings().enabled, isFalse);

      final settings = WorktreeCleanupSettings(
        enabled: true,
        rules: const WorktreeCleanupRules(
          inactiveDays: 30,
          noCommitsBeyondDefault: true,
          exemptIgnored: ['node_modules', '.dart_tool'],
        ),
        projects: const {
          'p1': ProjectCleanupPolicy(mode: WorktreeCleanupMode.off),
        },
        changedAt: now,
      );
      store.saveSettings(settings);
      final back = store.settings();
      expect(back.enabled, isTrue);
      expect(back.rules, settings.rules);
      expect(back.policyFor('p1').mode, WorktreeCleanupMode.off);
      expect(back.changedAt, now);
      expect(
        preferences.read(WorktreeCleanupStore.settingsKey),
        contains('"inactiveDays":30'),
      );
    });

    test('the removal log keeps the newest entries, capped', () {
      final store = WorktreeCleanupStore(FakeDataServer().store);
      for (var i = 0; i < WorktreeCleanupStore.logLimit + 5; i++) {
        store.appendLog(
          WorktreeCleanupLogEntry(
            at: now.add(Duration(minutes: i)),
            projectName: 'Demo',
            worktreePath: 'wt$i',
            environmentId: 'windows',
            rules: const [WorktreeCleanupRule.merged],
            removed: true,
          ),
        );
      }
      final log = store.log();
      expect(log, hasLength(WorktreeCleanupStore.logLimit));
      expect(log.first.worktreePath, 'wt${WorktreeCleanupStore.logLimit + 4}');
      expect(log.first.rules, [WorktreeCleanupRule.merged]);
    });
  });

  group('refusals', () {
    const rules = WorktreeCleanupRules();

    test('a clean, old, merged worktree has none', () {
      expect(refusalsFor(facts(), rules, now), isEmpty);
      expect(rulesMatched(facts(), rules, now).matched, [
        WorktreeCleanupRule.inactive,
        WorktreeCleanupRule.merged,
      ]);
    });

    test('each refusal stands alone, whatever a rule says', () {
      Iterable<WorktreeRefusalKind> kinds(WorktreeFacts f) =>
          refusalsFor(f, rules, now).map((r) => r.kind);

      expect(kinds(facts(live: ['Work'])), [WorktreeRefusalKind.activeSession]);
      expect(kinds(facts(sessionIds: ['a', 'b'])), [
        WorktreeRefusalKind.shared,
      ]);
      expect(kinds(facts(sessionIds: ['a'])), isEmpty);
      expect(
        kinds(facts(contents: const WorktreeContents(changes: ['a.txt']))),
        [WorktreeRefusalKind.uncommittedChanges],
      );
      expect(kinds(facts(madeHere: false)), [WorktreeRefusalKind.notMadeHere]);
      expect(
        kinds(facts(lastActivity: now.subtract(const Duration(hours: 3)))),
        [WorktreeRefusalKind.recentlyActive],
      );
    });

    test('ignored files keep it unless every one is an exempt name', () {
      Iterable<WorktreeRefusalKind> kinds(List<String> ignored) => refusalsFor(
        facts(contents: WorktreeContents(ignored: ignored)),
        rules,
        now,
      ).map((r) => r.kind);

      expect(kinds(['node_modules/', 'web/node_modules/']), isEmpty);
      expect(kinds(['node_modules/', 'build/']), [
        WorktreeRefusalKind.ignoredFiles,
      ]);
      expect(kinds(['.env']), [WorktreeRefusalKind.ignoredFiles]);
    });
  });

  group('rules', () {
    test('squash merges leave commits ahead, so neither git rule matches', () {
      final result = rulesMatched(
        facts(ahead: 2),
        const WorktreeCleanupRules(
          inactiveEnabled: false,
          noCommitsBeyondDefault: true,
        ),
        now,
      );
      expect(result.matched, isEmpty);
      expect(result.unmatched.single, contains('squash'));
    });

    test('an unknown age is not an old one', () {
      final unknown = WorktreeFacts(
        projectId: 'p1',
        projectName: 'Demo',
        repo: wt,
        path: wt,
      );
      final result = rulesMatched(
        unknown,
        const WorktreeCleanupRules(merged: false),
        now,
      );
      expect(result.matched, isEmpty);
      expect(result.unmatched.single, contains('no activity is recorded'));
    });

    test('an unresolved default branch matches neither git rule', () {
      final result = rulesMatched(
        facts(base: null, ahead: null),
        const WorktreeCleanupRules(
          inactiveEnabled: false,
          noCommitsBeyondDefault: true,
        ),
        now,
      );
      expect(result.matched, isEmpty);
    });
  });

  group('git reads', () {
    test('porcelain with --ignored splits changes from ignored paths', () {
      final contents = parseWorktreeContents(
        ' M lib/a.dart\n?? notes.txt\n!! build/\n!! "sp ace/"\n',
      );
      expect(contents.changes, ['lib/a.dart', 'notes.txt']);
      expect(contents.ignored, ['build/', 'sp ace/']);
    });

    test('a reflog line carries its time in the selector', () {
      final entries = parseReflog(
        'feat@{1789990666}\tcommit: c1\nfeat@{1789990000}\tbranch: Created\n'
        'HEAD@{1789980000}\t\n',
      );
      expect(entries, hasLength(3));
      expect(entries.first.at, DateTime.utc(2026, 9, 21, 11, 37, 46));
      expect(entries.first.isOwnCommit, isTrue);
      expect(entries[1].isOwnCommit, isFalse);
      expect(entries[2].subject, '');
    });
  });

  test('removeIfClean runs `git worktree remove` without --force', () async {
    final server = FakeDataServer()..environmentRows.upsert(windowsEnv());
    final runner = FakeCommandRunner();
    final service = WorktreeService(
      runnerFactory: FakeCommandRunnerFactory(fallback: runner),
      environmentOf: worktreeEnvironmentOf(
        EnvironmentsData(await server.connect()),
      ),
    );
    await service.removeIfClean(
      const EnvironmentPath(environmentId: 'windows', path: r'C:\src\app'),
      wt,
    );
    final args = runner.requests.single.arguments;
    expect(args, containsAllInOrder(['worktree', 'remove', wt.path]));
    expect(args, isNot(contains('--force')));
  });
}
