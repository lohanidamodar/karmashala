import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/git/data/worktree_setup_dao.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late WorktreeSetupDao dao;

  const worktree = EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\src\.karmashala-worktrees\app-s1',
  );

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    dao = WorktreeSetupDao(db);
  });
  tearDown(() => db.close());

  group('the setting', () {
    test('a checkout nobody configured reads as empty, not as null', () {
      expect(dao.get('r1'), const WorktreeSetup());
      expect(dao.get('r1').isEmpty, isTrue);
      expect(dao.getAll(), isEmpty);
    });

    test('round-trips a command and a copy list', () {
      const setup = WorktreeSetup(
        command: ['flutter', 'pub', 'get'],
        copyPaths: ['.dart_tool', 'macos/Vendor'],
      );
      dao.save('r1', setup, testTime);
      expect(dao.get('r1'), setup);
      expect(dao.getAll(), {'r1': setup});
    });

    test('saving twice updates the row rather than failing', () {
      dao.save('r1', const WorktreeSetup(copyPaths: ['.dart_tool']), testTime);
      dao.save(
        'r1',
        const WorktreeSetup(command: ['make', 'setup']),
        testTime.add(const Duration(minutes: 1)),
      );
      expect(dao.get('r1').command, ['make', 'setup']);
      expect(dao.get('r1').copyPaths, isEmpty);
    });

    test('emptying the setting removes the row, not just its values', () {
      dao.save('r1', const WorktreeSetup(command: ['make']), testTime);
      dao.save('r1', const WorktreeSetup(), testTime);
      expect(
        dao.getAll(),
        isEmpty,
        reason:
            'a configured-but-inert row would '
            'show in the list and do nothing',
      );
    });

    test('a copy-only setting stores no command at all', () {
      dao.save('r1', const WorktreeSetup(copyPaths: ['.env']), testTime);
      final stored = db.query(
        'SELECT command FROM worktree_setup WHERE repository_id = ?;',
        ['r1'],
      );
      expect(stored.single['command'], isNull);
      expect(dao.get('r1').command, isEmpty);
    });

    test('retiring the checkout takes its build recipe with it', () {
      dao.save('r1', const WorktreeSetup(command: ['make']), testTime);
      RepositoryDao(db).delete('r1');
      expect(dao.getAll(), isEmpty);
    });
  });

  group('what happened to a worktree', () {
    WorktreeSetupReport report({
      WorktreeCopyResult copy = WorktreeCopyResult.copied,
      DateTime? at,
    }) => WorktreeSetupReport(
      repositoryId: 'r1',
      worktreePath: worktree.path,
      environmentId: 'windows',
      ranAt: at ?? testTime,
      copies: [
        WorktreeCopyVerdict(
          path: '.dart_tool',
          result: copy,
          reason: 'because.',
        ),
      ],
    );

    test('nothing recorded is null — never a clean bill of health', () {
      expect(dao.lastRun('r1', worktree), isNull);
      expect(dao.runsFor('r1'), isEmpty);
    });

    test('a run round-trips with its age and its sentences', () {
      dao.record(report());
      final back = dao.lastRun('r1', worktree)!;
      expect(back.ranAt, testTime);
      expect(back.verdict, WorktreeSetupVerdict.ok);
      expect(back.copies.single.reason, 'because.');
      expect(back.worktreePath, worktree.path);
    });

    test('the stored verdict is queryable without decoding the detail', () {
      dao.record(report(copy: WorktreeCopyResult.failed));
      expect(
        db.query('SELECT verdict FROM worktree_setup_runs;').single['verdict'],
        'attention',
      );
    });

    test('a second run corrects the same worktree rather than piling up', () {
      dao.record(report(copy: WorktreeCopyResult.failed));
      dao.record(report(at: testTime.add(const Duration(hours: 1))));
      expect(dao.runsFor('r1'), hasLength(1));
      expect(dao.lastRun('r1', worktree)!.verdict, WorktreeSetupVerdict.ok);
      expect(
        dao.lastRun('r1', worktree)!.ranAt,
        testTime.add(const Duration(hours: 1)),
      );
    });

    test('two worktrees of one checkout keep their own verdicts', () {
      dao.record(report(copy: WorktreeCopyResult.failed));
      const other = EnvironmentPath(
        environmentId: 'windows',
        path: r'C:\src\.karmashala-worktrees\app-s2',
      );
      dao.record(
        WorktreeSetupReport(
          repositoryId: 'r1',
          worktreePath: other.path,
          environmentId: 'windows',
          ranAt: testTime,
          copies: const [],
        ),
      );
      expect(dao.runsFor('r1'), hasLength(2));
      expect(
        dao.lastRun('r1', worktree)!.verdict,
        WorktreeSetupVerdict.attention,
      );
      expect(dao.lastRun('r1', other)!.verdict, WorktreeSetupVerdict.ok);
    });

    test('the same path in another environment is another worktree', () {
      dao.record(report());
      expect(
        dao.lastRun('r1', worktree.copyWith(environmentId: 'wsl:Ubuntu')),
        isNotNull,
        reason: 'the key is the path, and one repository is in one environment',
      );
    });

    test('retiring the checkout takes its verdicts with it', () {
      dao.record(report());
      RepositoryDao(db).delete('r1');
      expect(dao.runsFor('r1'), isEmpty);
    });
  });

  group('v41 is the shape the setting and the verdict need', () {
    Map<String, Map<String, Object?>> columns(String table) => {
      for (final row in db.query('PRAGMA table_info($table);'))
        row['name']! as String: row,
    };

    test('the setting: a nullable command, and paths that default to none', () {
      final setting = columns('worktree_setup');
      expect(setting.keys, {
        'repository_id',
        'command',
        'copy_paths',
        'updated_at',
      });
      expect(
        setting['command']!['notnull'],
        0,
        reason:
            'no command is a '
            'complete setting',
      );
      expect(setting['copy_paths']!['dflt_value'], "'[]'");
      expect(setting['repository_id']!['pk'], 1);
    });

    test('the verdict: keyed by worktree, and never a defaulted exit code', () {
      final run = columns('worktree_setup_runs');
      expect(run.keys, {
        'repository_id',
        'worktree_path',
        'environment_id',
        'ran_at',
        'verdict',
        'detail',
      });
      // §19: a verdict with no age is a confident statement about a moment
      // nobody can identify.
      expect(run['ran_at']!['notnull'], 1);
      expect(run['repository_id']!['pk'], 1);
      expect(run['worktree_path']!['pk'], 2);
    });
  });

  group('the teardown command', () {
    test('round-trips beside the rest of the setting', () {
      const setup = WorktreeSetup(
        command: ['flutter', 'pub', 'get'],
        teardown: ['docker', 'compose', 'down'],
      );
      dao.save('r1', setup, testTime);
      expect(dao.get('r1'), setup);
      expect(dao.getAll()['r1'], setup);
    });

    test('is a setting on its own', () {
      const setup = WorktreeSetup(teardown: ['make', 'clean']);
      dao.save('r1', setup, testTime);
      expect(dao.get('r1').teardown, ['make', 'clean']);
      expect(dao.getAll()['r1']?.teardown, ['make', 'clean']);
    });

    test('clearing the setting clears it too', () {
      dao.save(
        'r1',
        const WorktreeSetup(teardown: ['make', 'clean']),
        testTime,
      );
      dao.clear('r1');
      expect(dao.get('r1'), const WorktreeSetup());
      expect(dao.getAll(), isEmpty);
    });
  });
}
