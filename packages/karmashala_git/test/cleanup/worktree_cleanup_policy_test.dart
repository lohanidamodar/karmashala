import 'dart:convert';

import 'package:agent_cli/process.dart';
import 'package:karmashala_git/cleanup.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/worktrees.dart';
import 'package:test/test.dart';

import '../support/fake_command_runner.dart';
import '../support/fixtures.dart';
import '../support/worktree_processes.dart';

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

    test('survive a round trip through their JSON, with no migration', () {
      expect(WorktreeCleanupSettings.fromJson(null).enabled, isFalse);
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
      final text = jsonEncode(settings.toJson());
      final back = WorktreeCleanupSettings.fromJson(jsonDecode(text));
      expect(back.enabled, isTrue);
      expect(back.rules, settings.rules);
      expect(back.policyFor('p1').mode, WorktreeCleanupMode.off);
      expect(back.changedAt, now);
      expect(text, contains('"inactiveDays":30'));
    });
  });

  group('what a sweep reports survives its JSON', () {
    Object? wire(Object? json) => jsonDecode(jsonEncode(json));

    test('a log entry, a sweep summary and the log they make', () {
      final entry = WorktreeCleanupLogEntry(
        at: now,
        projectName: 'Demo',
        worktreePath: wt.path,
        environmentId: 'windows',
        branch: 'x',
        rules: const [WorktreeCleanupRule.merged],
        removed: false,
        detail: 'git said no',
        automatic: false,
      );
      final summary = WorktreeCleanupSweepSummary(
        startedAt: now,
        finishedAt: now.add(const Duration(seconds: 3)),
        automatic: false,
        removed: 1,
        kept: 2,
        failed: 1,
        error: 'boom',
      );
      final log = WorktreeCleanupLog.fromJson(
        wire(WorktreeCleanupLog(entries: [entry], lastSweep: summary).toJson())!
            as Map<String, Object?>,
      );
      final back = log.entries.single;
      expect(back.at, now);
      expect(back.worktreePath, wt.path);
      expect(back.branch, 'x');
      expect(back.rules, [WorktreeCleanupRule.merged]);
      expect(back.removed, isFalse);
      expect(back.detail, 'git said no');
      expect(back.automatic, isFalse);
      final last = log.lastSweep!;
      expect(last.startedAt, now);
      expect(last.finishedAt, now.add(const Duration(seconds: 3)));
      expect((last.removed, last.kept, last.failed), (1, 2, 1));
      expect(last.error, 'boom');
      expect(WorktreeCleanupLog.fromJson(const {}).entries, isEmpty);
    });

    test('a report and its verdicts, facts and refusals included', () {
      final report = WorktreeCleanupReport(
        at: now,
        dryRun: true,
        notes: const ['skipped an SSH host'],
        notInspected: 4,
        verdicts: [
          WorktreeCleanupVerdict(
            facts: facts(
              live: const ['Refactor'],
              sessionIds: const ['s1'],
              contents: const WorktreeContents(
                changes: ['a.dart'],
                ignored: ['build/'],
              ),
            ),
            outcome: WorktreeCleanupOutcome.kept,
            matched: const [WorktreeCleanupRule.inactive],
            refusals: const [
              WorktreeRefusal(WorktreeRefusalKind.activeSession, 'Running'),
            ],
            unmatched: const ['Merged: no'],
            error: 'git failed',
            recheckedBeforeRemoval: true,
          ),
        ],
      );
      final back = WorktreeCleanupReport.fromJson(
        wire(report.toJson())! as Map<String, Object?>,
      );
      expect(back.at, now);
      expect(back.dryRun, isTrue);
      expect(back.notes, ['skipped an SSH host']);
      expect(back.notInspected, 4);
      final verdict = back.verdicts.single;
      expect(verdict.outcome, WorktreeCleanupOutcome.kept);
      expect(verdict.matched, [WorktreeCleanupRule.inactive]);
      expect(verdict.refusals.single.kind, WorktreeRefusalKind.activeSession);
      expect(verdict.refusals.single.detail, 'Running');
      expect(verdict.unmatched, ['Merged: no']);
      expect(verdict.error, 'git failed');
      expect(verdict.recheckedBeforeRemoval, isTrue);
      final f = verdict.facts;
      expect(f.path, wt);
      expect(f.repo.path, r'C:\src\app');
      expect(f.liveSessions, ['Refactor']);
      expect(f.sessionIds, ['s1']);
      expect(f.contents!.changes, ['a.dart']);
      expect(f.contents!.ignored, ['build/']);
      expect(f.base, 'origin/main');
      expect(f.commitsBeyondBase, 0);
      expect(f.madeCommits, isTrue);
      expect(f.lastActivity, now.subtract(const Duration(days: 30)));
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
    final runner = FakeCommandRunner();
    final service = WorktreeService(
      runnerFactory: FakeCommandRunnerFactory(fallback: runner),
      environmentOf: environmentsOf([windowsEnv()]),
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
