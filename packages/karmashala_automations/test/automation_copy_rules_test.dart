import 'dart:convert';

import 'package:karmashala_automations/karmashala_automations.dart';
import 'package:karmashala_automations/store.dart';
import 'package:karmashala_core/verdicts.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'service/service_fixtures.dart';

/// A client's copy answers what the DAOs answer over the same rows: the
/// rules `AutomationCopyReads`, `ResumeCopyReads` and `ProjectCheckCopyReads`
/// are tested against the store, and the JSON carries every field.
void main() {
  late AppDatabase db;
  late AutomationDao automations;
  late ScheduledResumeDao resumes;
  late ProjectCheckDao checks;
  final t0 = fixtureTime;

  setUp(() {
    db = fixtureDatabase();
    automations = AutomationDao(db);
    resumes = ScheduledResumeDao(db);
    checks = ProjectCheckDao(db);
    insertSession(db, 's1');
    insertSession(db, 's2');
    automations
      ..insert(fixtureAutomation(id: 'b', armedAt: t0))
      ..insert(
        fixtureAutomation(
          id: 'a',
          armedAt: t0,
        ).copyWith(name: 'Alpha', enabled: false),
      );
    var n = 0;
    AutomationRun run(
      String automationId,
      Duration after,
      AutomationRunState state, {
      String? sessionId,
    }) => AutomationRun(
      id: 'run${++n}',
      automationId: automationId,
      scheduledFor: t0.add(after),
      firedAt: t0.add(after),
      state: state,
      reason: '',
      sessionId: sessionId,
      finishedAt: state.isLive
          ? null
          : t0.add(after + const Duration(minutes: 5)),
    );
    for (final r in [
      run('b', const Duration(hours: 1), AutomationRunState.finished),
      run(
        'b',
        const Duration(hours: 3),
        AutomationRunState.running,
        sessionId: 's1',
      ),
      run('b', const Duration(hours: 2), AutomationRunState.queued),
      run(
        'a',
        const Duration(hours: 1),
        AutomationRunState.missed,
        sessionId: 's1',
      ),
    ]) {
      automations.insertRun(r);
    }
    automations
      ..insertRunCheck(
        AutomationCheckVerdict(
          runId: 'run1',
          ordinal: 2,
          name: 'lint',
          command: const ['lint'],
          verdict: VerificationVerdict.pass,
          reason: '',
          checkedAt: t0,
        ),
      )
      ..insertRunCheck(
        AutomationCheckVerdict(
          runId: 'run1',
          ordinal: 1,
          name: 'tests',
          command: const ['test'],
          verdict: VerificationVerdict.fail,
          reason: 'red',
          checkedAt: t0,
        ),
      )
      ..markMessaged('s2', const ['b'], t0);
    ScheduledResume resume(
      String id,
      String session,
      ScheduledResumeState state,
      Duration at,
    ) => ScheduledResume(
      id: id,
      sessionId: session,
      fireAt: t0.add(at),
      state: state,
      scheduledAt: t0,
      finishedAt: state.isLive ? null : t0.add(at),
    );
    resumes
      ..replaceFor(
        resume('x1', 's1', ScheduledResumeState.done, const Duration(hours: 1)),
        now: t0,
      )
      ..replaceFor(
        resume(
          'x2',
          's1',
          ScheduledResumeState.failed,
          const Duration(hours: 2),
        ),
        now: t0,
      )
      ..replaceFor(
        resume(
          'x3',
          's2',
          ScheduledResumeState.pending,
          const Duration(hours: 4),
        ),
        now: t0,
      );
    checks
      ..insert(
        ProjectCheck(
          id: 'c2',
          repositoryId: 'r1',
          name: 'two',
          command: const ['2'],
          createdAt: t0.add(const Duration(minutes: 1)),
        ),
      )
      ..insert(
        ProjectCheck(
          id: 'c1',
          repositoryId: 'r1',
          name: 'one',
          command: const ['1'],
          createdAt: t0,
        ),
      )
      ..setVerificationEnabled('r1', enabled: true, now: t0);
  });
  tearDown(() => db.close());

  String j(Object? value) => jsonEncode(value);

  test('the automation reads match the store over the copied rows', () {
    final copy = _Copy(
      automations.getAll(),
      automations.copiedRuns(),
      automations.checksOf(['run1', 'run2', 'run3', 'run4']),
      automations.origins(),
    );
    List<String> ids(Iterable<Object> rows) => [
      for (final r in rows)
        switch (r) {
          Automation(:final id) => id,
          AutomationRun(:final id) => id,
          _ => '$r',
        },
    ];
    expect(ids(copy.getAll()), ids(automations.getAll()));
    expect(ids(copy.enabled()), ids(automations.enabled()));
    expect(ids(copy.liveRuns()), ids(automations.liveRuns()));
    expect(ids(copy.runsFor('b')), ids(automations.runsFor('b')));
    expect(copy.liveRunOf('b')?.id, automations.liveRunOf('b')?.id);
    expect(copy.runForSession('s1')?.id, automations.runForSession('s1')?.id);
    expect(copy.originOfSession('s1'), automations.originOfSession('s1'));
    expect(copy.lastFinishedAt('b'), automations.lastFinishedAt('b'));
    expect(copy.lastTouchedAt('b'), automations.lastTouchedAt('b'));
    expect(
      copy.lastObservedOccurrence('b'),
      automations.lastObservedOccurrence('b'),
    );
    expect(
      j([for (final v in copy.checksFor('run1')) checkVerdictToJson(v)]),
      j([for (final v in automations.checksFor('run1')) checkVerdictToJson(v)]),
    );
    expect(copy.origins, {
      's2': ['b'],
    });
  });

  test('the resume reads match the store over the copied rows', () {
    final copy = _Resumes(resumes.copied());
    expect(copy.liveFor('s2')?.id, resumes.liveFor('s2')?.id);
    expect(copy.lastEndedFor('s1')?.id, resumes.lastEndedFor('s1')?.id);
    expect(
      [for (final r in copy.live()) r.id],
      [for (final r in resumes.live()) r.id],
    );
    expect(
      [for (final r in copy.recentEnded()) r.id],
      [for (final r in resumes.recentEnded()) r.id],
    );
    expect(
      j([for (final r in resumes.copied()) scheduledResumeToJson(r)]),
      j([
        for (final r in resumes.copied())
          scheduledResumeToJson(
            scheduledResumeFromJson(
              (jsonDecode(j(scheduledResumeToJson(r))) as Map)
                  .cast<String, Object?>(),
            ),
          ),
      ]),
    );
  });

  test('the project check reads match the store', () {
    final copy = _Checks(checks.all(), checks.verifiedRepositories());
    expect(copy.forRepository('r1'), checks.forRepository('r1'));
    expect(copy.countFor('r1'), checks.countFor('r1'));
    expect(copy.isVerificationEnabled('r1'), isTrue);
    expect(copy.isVerificationEnabled('r2'), isFalse);
  });

  test('an automation and a run survive their JSON', () {
    for (final a in automations.getAll()) {
      final back = automationFromJson(
        (jsonDecode(j(automationToJson(a))) as Map).cast<String, Object?>(),
      );
      expect(j(automationToJson(back)), j(automationToJson(a)));
    }
    for (final r in automations.copiedRuns()) {
      final back = automationRunFromJson(
        (jsonDecode(j(automationRunToJson(r))) as Map).cast<String, Object?>(),
      );
      expect(j(automationRunToJson(back)), j(automationRunToJson(r)));
    }
  });

  test('an event run queues behind whatever holds its checkout', () {
    final written = queueEventRunIn(
      automations,
      automations.getById('a')!,
      AutomationRun(
        id: 'ev',
        automationId: 'a',
        scheduledFor: t0,
        firedAt: t0,
        state: AutomationRunState.running,
        reason: 'because',
      ),
    );
    expect(written.state, AutomationRunState.queued);
    expect(written.reason, contains('is already waiting for it'));
  });
}

class _Copy extends AutomationCopyReads {
  _Copy(List<Automation> a, List<AutomationRun> r, this._checks, this.origins)
    : _automations = {for (final x in a) x.id: x},
      _runs = {for (final x in r) x.id: x};

  final Map<String, Automation> _automations;
  final Map<String, AutomationRun> _runs;
  final Map<String, List<AutomationCheckVerdict>> _checks;
  final Map<String, List<String>> origins;

  @override
  Iterable<Automation> get automationRows => _automations.values;
  @override
  Iterable<AutomationRun> get runRows => _runs.values;
  @override
  Automation? automationRow(String id) => _automations[id];
  @override
  AutomationRun? runRow(String id) => _runs[id];
  @override
  List<AutomationCheckVerdict>? checkRows(String runId) => _checks[runId];
  @override
  List<String>? originRow(String sessionId) => origins[sessionId];

  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('a read-only copy');
}

class _Resumes extends ResumeCopyReads {
  _Resumes(List<ScheduledResume> rows)
    : _rows = {for (final r in rows) r.id: r};
  final Map<String, ScheduledResume> _rows;
  @override
  Iterable<ScheduledResume> get resumeRows => _rows.values;
  @override
  ScheduledResume? resumeRow(String id) => _rows[id];

  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('a read-only copy');
}

class _Checks extends ProjectCheckCopyReads {
  _Checks(this._all, this._verified);
  final List<ProjectCheck> _all;
  final Set<String> _verified;
  @override
  Iterable<ProjectCheck> get checkRowsAll => _all;
  @override
  Set<String> get verifiedRows => _verified;
}
