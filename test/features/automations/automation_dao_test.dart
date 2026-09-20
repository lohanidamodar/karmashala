import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_automations/persistence.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_automations/checks.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';

import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late AutomationDao dao;
  late ProjectCheckDao checks;

  Automation nightly({
    String id = 'auto1',
    String name = 'Nightly sweep',
    AutomationSchedule? schedule,
    bool enabled = true,
    PermissionSelection? permission,
  }) => Automation(
    id: id,
    repositoryId: 'r1',
    name: name,
    schedule: schedule ?? const AutomationSchedule.cron('0 3 * * *'),
    agentInstallationId: 'a1',
    prompt: 'Run the checks and fix what broke.',
    permissionMode: permission,
    enabled: enabled,
    armedAt: testTime,
  );

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    dao = AutomationDao(db);
    checks = ProjectCheckDao(db);
  });
  tearDown(() => db.close());

  group('automations', () {
    test('a cron automation round-trips, schedule and mode included', () {
      dao.insert(
        nightly(permission: const PermissionSelection({'mode': 'auto'})),
      );
      final read = dao.getById('auto1')!;
      expect(read.name, 'Nightly sweep');
      expect(read.schedule.cron, '0 3 * * *');
      expect(read.schedule.firesAt, isNull);
      expect(read.schedule.isRecurring, isTrue);
      expect(read.permissionMode?.canonical, 'mode=auto');
      expect(read.enabled, isTrue);
      expect(read.armedAt, testTime);
    });

    test('a one-shot round-trips as an instant, not as a cron', () {
      final at = DateTime.utc(2026, 9, 9, 3);
      dao.insert(nightly(schedule: AutomationSchedule.once(at)));
      final read = dao.getById('auto1')!;
      expect(read.schedule.isOnce, isTrue);
      expect(read.schedule.firesAt, at);
      expect(read.schedule.cron, isNull);
    });

    test('a mode nobody chose reads back as null, not as a default', () {
      dao.insert(nightly());
      expect(dao.getById('auto1')!.permissionMode, isNull);
    });

    test('pausing keeps the row, its arming and its runs', () {
      dao.insert(nightly());
      dao.insertRun(
        AutomationRun(
          id: 'run1',
          automationId: 'auto1',
          scheduledFor: testTime,
          firedAt: testTime,
          state: AutomationRunState.finished,
          reason: '',
        ),
      );
      dao.setEnabled('auto1', enabled: false);
      final read = dao.getById('auto1')!;
      expect(read.enabled, isFalse);
      expect(read.armedAt, testTime);
      expect(dao.runsFor('auto1'), hasLength(1));
      expect(dao.enabled(), isEmpty);
    });

    test('deleting one takes its runs with it', () {
      dao.insert(nightly());
      dao.insertRun(
        AutomationRun(
          id: 'run1',
          automationId: 'auto1',
          scheduledFor: testTime,
          firedAt: testTime,
          state: AutomationRunState.finished,
          reason: '',
        ),
      );
      dao.delete('auto1');
      expect(dao.getById('auto1'), isNull);
      expect(dao.runById('run1'), isNull);
    });

    test('a retired checkout takes its automations with it', () {
      dao.insert(nightly());
      RepositoryDao(db).delete('r1');
      expect(dao.getAll(), isEmpty);
    });
  });

  group('runs', () {
    AutomationRun run({
      String id = 'run1',
      AutomationRunState state = AutomationRunState.running,
      String reason = '',
      DateTime? scheduledFor,
      String? sessionId,
      int? commitsMade,
    }) => AutomationRun(
      id: id,
      automationId: 'auto1',
      scheduledFor: scheduledFor ?? testTime,
      firedAt: testTime,
      state: state,
      reason: reason,
      sessionId: sessionId,
      commitsMade: commitsMade,
    );

    setUp(() => dao.insert(nightly()));

    test('every state round-trips by name', () {
      for (final state in AutomationRunState.values) {
        if (state == AutomationRunState.unrecognised) continue;
        dao.insertRun(run(id: state.name, state: state));
        expect(dao.runById(state.name)!.state, state);
      }
    });

    test('a state this build cannot read is not guessed at', () {
      db.execute(
        "INSERT INTO automation_runs (id, automation_id, scheduled_for, "
        "fired_at, state, reason) VALUES ('x', 'auto1', ?, ?, 'exploded', '');",
        [testTime.toIso8601String(), testTime.toIso8601String()],
      );
      expect(dao.runById('x')!.state, AutomationRunState.unrecognised);
    });

    test('a missed row carries its reason and when it was due', () {
      final due = DateTime.utc(2026, 9, 8, 3);
      dao.insertRun(
        run(
          state: AutomationRunState.missed,
          reason: 'Karmashala was not running when this was due.',
          scheduledFor: due,
        ),
      );
      final read = dao.runById('run1')!;
      expect(read.scheduledFor, due);
      expect(read.firedAt, testTime);
      expect(read.reason, isNotEmpty);
    });

    test('commits made is null until it is counted, never zero by default', () {
      dao.insertRun(run());
      expect(dao.runById('run1')!.commitsMade, isNull);
      dao.updateRun(dao.runById('run1')!.copyWith(commitsMade: 0));
      expect(dao.runById('run1')!.commitsMade, 0);
    });

    test('live runs are the queue, oldest due first', () {
      dao.insertRun(
        run(
          id: 'later',
          state: AutomationRunState.queued,
          scheduledFor: DateTime.utc(2026, 9, 9, 4),
        ),
      );
      dao.insertRun(
        run(
          id: 'earlier',
          state: AutomationRunState.queued,
          scheduledFor: DateTime.utc(2026, 9, 9, 3),
        ),
      );
      dao.insertRun(run(id: 'done', state: AutomationRunState.finished));
      expect(dao.liveRuns().map((r) => r.id), ['earlier', 'later']);
    });

    test('a run is findable by the session it started', () {
      dao.insertRun(run(sessionId: 's1'));
      expect(dao.runForSession('s1')?.id, 'run1');
      expect(dao.runForSession('nope'), isNull);
    });

    test('the newest occurrence observed is the sweep floor', () {
      expect(dao.lastObservedOccurrence('auto1'), isNull);
      dao.insertRun(run(id: 'a', scheduledFor: DateTime.utc(2026, 9, 8, 3)));
      dao.insertRun(run(id: 'b', scheduledFor: DateTime.utc(2026, 9, 9, 3)));
      expect(dao.lastObservedOccurrence('auto1'), DateTime.utc(2026, 9, 9, 3));
    });
  });

  group('the preconditions the gate reads', () {
    test('a checkout nobody configured has verification off', () {
      expect(checks.isVerificationEnabled('r1'), isFalse);
      expect(checks.countFor('r1'), 0);
    });

    test('turning it on is a decision that is stored', () {
      checks.setVerificationEnabled('r1', enabled: true, now: testTime);
      expect(checks.isVerificationEnabled('r1'), isTrue);
      expect(checks.verifiedRepositories(), {'r1'});
      checks.setVerificationEnabled('r1', enabled: false, now: testTime);
      expect(checks.isVerificationEnabled('r1'), isFalse);
      expect(checks.verifiedRepositories(), isEmpty);
    });

    test('a check round-trips as argv', () {
      checks.insert(
        ProjectCheck(
          id: 'c1',
          repositoryId: 'r1',
          name: 'the test suite',
          command: const ['flutter', 'test', '--exclude-tags=live-ssh'],
          createdAt: testTime,
        ),
      );
      final read = checks.forRepository('r1').single;
      expect(read.name, 'the test suite');
      expect(read.command, ['flutter', 'test', '--exclude-tags=live-ssh']);
      expect(checks.countFor('r1'), 1);
      checks.delete('c1');
      expect(checks.countFor('r1'), 0);
    });

    test('a command row this code did not write reads as no command', () {
      db.execute(
        "INSERT INTO project_checks (id, repository_id, name, command, "
        "created_at) VALUES ('c2', 'r1', 'bad', 'not json', ?);",
        [testTime.toIso8601String()],
      );
      expect(checks.forRepository('r1').single.command, isEmpty);
    });

    test('a blank name and an empty command are both refused, in words', () {
      expect(projectCheckNameRefusal('  '), contains('needs a name'));
      expect(projectCheckNameRefusal('analyze'), isNull);
      expect(projectCheckCommandRefusal(const []), contains('checks nothing'));
      expect(projectCheckCommandRefusal(const ['flutter', 'analyze']), isNull);
    });
  });
}
