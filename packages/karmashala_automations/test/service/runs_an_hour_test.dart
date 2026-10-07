import 'package:karmashala_automations/karmashala_automations.dart';
import 'package:karmashala_automations/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'service_fixtures.dart';

class _Firing implements AutomationFiring {
  _Firing(this.dao);
  final AutomationDao dao;
  final started = <String>[];

  @override
  Future<void> fire(
    Automation automation,
    DateTime scheduledFor, {
    String note = '',
    AutomationRun? queued,
  }) async {
    started.add(queued!.id);
    dao.updateRun(queued.copyWith(state: AutomationRunState.running));
  }
}

class _NoResumes implements ScheduledResumeFiring {
  @override
  Future<void> fire(ScheduledResume resume, {String note = ''}) async {}
}

/// Runs an hour for every kind, and one run per automation per place at a
/// time: later triggers wait (up to a limit) or merge into the one waiting.
void main() {
  final now = fixtureTime;
  late AppDatabase db;
  late AutomationDao dao;

  AutomationRun run(
    String id, {
    AutomationRunState state = AutomationRunState.running,
    Duration ago = Duration.zero,
    String? branch,
    AutomationRunCause? startedBy,
  }) => AutomationRun(
    id: id,
    automationId: 'auto1',
    scheduledFor: now.subtract(ago),
    firedAt: now.subtract(ago),
    state: state,
    reason: '',
    startedBy: startedBy,
    variables: branch == null ? const {} : {'github.pr.branch': branch},
  );

  Automation rule({
    int perHour = 3,
    AutomationOverlap overlap = AutomationOverlap.queue,
    int limit = 2,
  }) => fixtureAutomation(
    armedAt: now,
  ).copyWith(runsPerHour: perHour, overlap: overlap, queueLimit: limit);

  setUp(() {
    db = fixtureDatabase();
    dao = AutomationDao(db);
  });
  tearDown(() => db.close());

  group('the rule', () {
    test(
      'a run an hour too many is refused; misses and Run now do not count',
      () {
        final recent = [
          run(
            'a',
            state: AutomationRunState.finished,
            ago: const Duration(minutes: 50),
          ),
          run(
            'b',
            state: AutomationRunState.failed,
            ago: const Duration(minutes: 30),
          ),
          run(
            'c',
            state: AutomationRunState.missed,
            ago: const Duration(minutes: 20),
          ),
          run(
            'd',
            state: AutomationRunState.finished,
            startedBy: AutomationRunCause.runNow,
          ),
          run(
            'e',
            state: AutomationRunState.finished,
            ago: const Duration(minutes: 61),
          ),
        ];
        expect(
          admitRun(rule(), lane: '', recent: recent, now: now),
          isA<AdmitStart>(),
        );
        recent.add(run('f', state: AutomationRunState.finished));
        expect(
          admitRun(rule(), lane: '', recent: recent, now: now),
          isA<AdmitRefuse>().having(
            (r) => r.reason,
            'reason',
            contains('3 runs'),
          ),
        );
        expect(
          admitRun(rule(), lane: '', recent: recent, now: now, byPerson: true),
          isA<AdmitStart>(),
          reason: 'Run now is a person\'s act',
        );
        expect(
          admitRun(rule(perHour: 0), lane: '', recent: recent, now: now),
          isA<AdmitStart>(),
          reason: 'zero is no limit',
        );
      },
    );

    test('behind its own run a trigger queues, up to the limit', () {
      final recent = [run('live')];
      expect(
        admitRun(rule(perHour: 10), lane: '', recent: recent, now: now),
        isA<AdmitQueue>(),
      );
      recent.addAll([
        run('w1', state: AutomationRunState.queued),
        run('w2', state: AutomationRunState.queued),
      ]);
      expect(
        admitRun(rule(perHour: 10), lane: '', recent: recent, now: now),
        isA<AdmitRefuse>().having(
          (r) => r.reason,
          'reason',
          contains('already waiting'),
        ),
      );
    });

    test('merge keeps one waiting, which runs once for all', () {
      final merging = rule(overlap: AutomationOverlap.merge);
      final recent = [run('live')];
      expect(
        admitRun(merging, lane: '', recent: recent, now: now),
        isA<AdmitQueue>(),
      );
      recent.add(run('w1', state: AutomationRunState.queued));
      expect(
        admitRun(merging, lane: '', recent: recent, now: now),
        isA<AdmitRefuse>().having(
          (r) => r.reason,
          'reason',
          contains('Merged'),
        ),
      );
    });

    test('one run per worktree: another branch is not held up', () {
      final recent = [run('live', branch: 'feat/a')];
      expect(
        admitRun(rule(), lane: 'feat/b', recent: recent, now: now),
        isA<AdmitStart>(),
      );
      expect(
        admitRun(rule(), lane: 'feat/a', recent: recent, now: now),
        isA<AdmitQueue>(),
      );
    });

    test('limits round-trip through the store and the wire', () {
      final saved = rule(
        perHour: 7,
        overlap: AutomationOverlap.merge,
        limit: 5,
      );
      dao.insert(saved);
      final read = dao.getById('auto1')!;
      expect(read.runsPerHour, 7);
      expect(read.overlap, AutomationOverlap.merge);
      expect(read.queueLimit, 5);
      final wired = automationFromJson(automationToJson(read));
      expect(
        (wired.runsPerHour, wired.overlap, wired.queueLimit),
        (7, AutomationOverlap.merge, 5),
      );
    });
  });

  group('the queue', () {
    late _Firing firing;
    late AutomationScheduler scheduler;

    setUp(() {
      dao.insert(rule());
      firing = _Firing(dao);
      scheduler = AutomationScheduler(
        automations: dao,
        resumes: ScheduledResumeDao(db),
        sessionOf: (_) => null,
        firing: firing,
        resumeFiring: _NoResumes(),
        timer: ManualAutomationTimer(),
        now: () => now,
        newId: () => 'id',
      );
    });

    test('a branch\'s waiting run starts when that branch is free, whatever '
        'runs on another', () async {
      dao
        ..insertRun(run('a1', branch: 'feat/a'))
        ..insertRun(run('b1', branch: 'feat/b'))
        ..insertRun(
          run('a2', branch: 'feat/a', state: AutomationRunState.queued),
        );
      await scheduler.drain('r1');
      expect(firing.started, isEmpty, reason: 'feat/a is still running');

      dao.updateRun(
        dao.runById('a1')!.copyWith(state: AutomationRunState.finished),
      );
      await scheduler.drain('r1');
      expect(firing.started, ['a2'], reason: 'feat/b running holds nothing');
    });

    test('a checkout run still waits for the checkout', () async {
      dao
        ..insertRun(run('c1'))
        ..insertRun(run('c2', state: AutomationRunState.queued));
      await scheduler.drain('r1');
      expect(firing.started, isEmpty);
      dao.updateRun(
        dao.runById('c1')!.copyWith(state: AutomationRunState.finished),
      );
      await scheduler.drain('r1');
      expect(firing.started, ['c2']);
    });

    test('a scheduled fire past its hour is recorded, not started', () async {
      for (var i = 0; i < 3; i++) {
        dao.insertRun(
          run(
            'f$i',
            state: AutomationRunState.finished,
            ago: Duration(minutes: 10 + i),
          ),
        );
      }
      dao.update(
        rule().copyWith(
          schedule: AutomationSchedule.once(now),
          armedAt: now.subtract(const Duration(minutes: 1)),
        ),
      );
      await scheduler.reconcile();
      expect(firing.started, isEmpty);
      final newest = dao.runsFor('auto1').first;
      expect(newest.state, AutomationRunState.missed);
      expect(newest.reason, contains('in the last hour'));
    });
  });
}
