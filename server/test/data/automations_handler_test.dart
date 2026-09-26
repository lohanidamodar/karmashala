import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/checks.dart';
import 'package:karmashala_automations/resumes.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_automations/store.dart';
import 'package:karmashala_core/verdicts.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// The automations domain at the server (slice 1e): the rules each write
/// follows, what other clients are told, the scheduler told after a write,
/// and the copy a client is given.
void main() {
  late AppDatabase db;
  late DataService service;
  late DataSession app;
  late List<DataChanges> told;
  late int written;
  final now = DateTime.utc(2026, 9, 27, 12);

  setUp(() {
    db = AppDatabase.memory();
    service = DataService(db, clock: () => now);
    written = 0;
    service.automationsWritten = () => written++;
    app = service.open((_) {});
    told = [];
    service.open(told.add).handle(const DataSubscribe());
    const at = '2026-01-01T00:00:00.000Z';
    db.execute(
      'INSERT INTO execution_environments (id, kind, name, created_at) '
      "VALUES ('windows', 'windowsNative', 'Windows', ?);",
      [at],
    );
    db.execute(
      'INSERT INTO projects '
      '(id, name, root_environment_id, root_path, created_at) '
      "VALUES ('p1', 'Demo', 'windows', 'C:\\src', ?);",
      [at],
    );
    db.execute(
      'INSERT INTO repositories '
      '(id, project_id, name, environment_id, path, created_at) '
      "VALUES ('r1', 'p1', 'r1', 'windows', 'C:\\src\\r1', ?);",
      [at],
    );
    db.execute(
      'INSERT INTO agent_installations '
      '(id, agent_kind, environment_id, executable_path, created_at) '
      "VALUES ('a1', 'claude-code', 'windows', 'claude', ?);",
      [at],
    );
    db.execute(
      'INSERT INTO sessions (id, repository_id, agent_installation_id, title, '
      "use_worktree, status, created_at) VALUES ('s1', 'r1', 'a1', 'Work', 0, "
      "'running', ?);",
      [at],
    );
  });
  tearDown(() => db.close());

  Matcher refused(DataRefusalCode code, [String? words]) => throwsA(
    isA<DataRefused>()
        .having((r) => r.code, 'code', code)
        .having((r) => r.message, 'message', contains(words ?? '')),
  );

  Automation rule({String id = 'auto1', String name = 'Nightly'}) => Automation(
    id: id,
    repositoryId: 'r1',
    name: name,
    schedule: const AutomationSchedule.cron('0 3 * * *'),
    agentInstallationId: 'a1',
    prompt: 'tidy up',
    permissionMode: null,
    enabled: true,
    armedAt: now,
  );

  AutomationRun run(
    String id, {
    AutomationRunState state = AutomationRunState.running,
    String automationId = 'auto1',
  }) => AutomationRun(
    id: id,
    automationId: automationId,
    scheduledFor: now,
    firedAt: now,
    state: state,
    reason: '',
  );

  ScheduledResume resume(String id) => ScheduledResume(
    id: id,
    sessionId: 's1',
    fireAt: now.add(const Duration(hours: 1)),
    state: ScheduledResumeState.pending,
    scheduledAt: now,
  );

  AutomationsSnapshot snapshot() => app.handle(const AutomationsList()).value;

  List<DataChange> lastTold() => told.last.changes;

  test(
    'a saved automation is stored, told, and the scheduler looks again',
    () async {
      final saved = app.handle(AutomationSave(rule())).value;
      expect(saved.name, 'Nightly');
      expect(AutomationDao(db).getById('auto1')!.prompt, 'tidy up');
      expect(lastTold().single, isA<AutomationChanged>());
      await pumpEventQueue();
      expect(written, 1);
      expect(snapshot().automations.single.id, 'auto1');
    },
  );

  test('a save is refused without a name or a checkout', () {
    expect(
      () => app.handle(AutomationSave(rule(name: '  '))),
      refused(DataRefusalCode.invalid, 'needs a name'),
    );
    expect(
      () => app.handle(
        AutomationSave(
          Automation(
            id: 'x',
            repositoryId: 'gone',
            name: 'X',
            schedule: const AutomationSchedule.cron('0 3 * * *'),
            agentInstallationId: 'a1',
            prompt: 'p',
            permissionMode: null,
            enabled: true,
            armedAt: now,
          ),
        ),
      ),
      refused(DataRefusalCode.notFound, 'gone'),
    );
  });

  test('outcomes spend and refill the failure budget; a disable says why', () {
    app.handle(AutomationSave(rule()));
    app.handle(const AutomationRecordOutcome('auto1', failed: true));
    final twice = app
        .handle(const AutomationRecordOutcome('auto1', failed: true))
        .value;
    expect(twice.consecutiveFailures, 2);
    final disabled = app
        .handle(const AutomationDisable('auto1', 'broken'))
        .value;
    expect((disabled.enabled, disabled.disabledReason), (false, 'broken'));
    final back = app
        .handle(const AutomationRecordOutcome('auto1', failed: false))
        .value;
    expect((back.consecutiveFailures, back.disabledReason), (0, null));
    expect(
      () => app.handle(const AutomationSetEnabled('nope', enabled: true)),
      refused(DataRefusalCode.notFound),
    );
  });

  test('a run is put, then rewritten in place; its checks follow it', () {
    app.handle(AutomationSave(rule()));
    app.handle(AutomationRunPut(run('run1')));
    expect(lastTold().single, isA<AutomationRunChanged>());
    app.handle(
      AutomationRunPut(
        run(
          'run1',
        ).copyWith(state: AutomationRunState.finished, sessionId: 's1'),
      ),
    );
    expect(
      AutomationDao(db).runById('run1')!.state,
      AutomationRunState.finished,
    );
    app.handle(
      AutomationRunCheckAdd(
        AutomationCheckVerdict(
          runId: 'run1',
          ordinal: 1,
          name: 'tests',
          command: const ['make', 'test'],
          verdict: VerificationVerdict.pass,
          reason: '',
          checkedAt: now,
        ),
      ),
    );
    final observed = app.handle(AutomationRunChecksObserved('run1', now)).value;
    expect(observed.checksObservedAt, now);
    final copy = snapshot();
    expect(copy.runs.single.id, 'run1');
    expect(copy.checks['run1']!.single.name, 'tests');
    expect(
      () => app.handle(AutomationRunPut(run('r9', automationId: 'none'))),
      refused(DataRefusalCode.notFound),
    );
  });

  test('an event run queues behind the checkout, or is missed beside its '
      'own live run', () {
    app.handle(AutomationSave(rule()));
    app.handle(AutomationSave(rule(id: 'auto2', name: 'Other')));
    app.handle(AutomationRunPut(run('busy', automationId: 'auto2')));
    final queued = app.handle(AutomationEventRunQueue(run('ev1'))).value;
    expect(queued.state, AutomationRunState.queued);
    expect(queued.reason, contains('"Other" is running there'));
    final missed = app.handle(AutomationEventRunQueue(run('ev2'))).value;
    expect(missed.state, AutomationRunState.missed);
  });

  test('deleting an automation takes its runs and is told once', () {
    app.handle(AutomationSave(rule()));
    app.handle(AutomationRunPut(run('run1')));
    app.handle(const AutomationDelete('auto1'));
    expect(lastTold().single, isA<AutomationRemoved>());
    expect(AutomationDao(db).runById('run1'), isNull);
  });

  test('origins are marked at the server clock and cleared', () {
    app.handle(const AutomationOriginMark('s1', ['auto1']));
    expect(AutomationDao(db).messagedOrigin('s1'), ['auto1']);
    expect(snapshot().origins, {
      's1': ['auto1'],
    });
    app.handle(const AutomationOriginClear('s1'));
    expect((lastTold().single as AutomationOriginChanged).origin, isEmpty);
    expect(
      () => app.handle(const AutomationOriginMark('ghost', ['a'])),
      refused(DataRefusalCode.notFound),
    );
  });

  test('project checks: the gate\'s refusals, the server\'s stamp, the '
      'verification switch', () {
    expect(
      () => app.handle(
        ProjectCheckAdd(
          ProjectCheck(
            id: 'c1',
            repositoryId: 'r1',
            name: 'tests',
            command: const [],
            createdAt: DateTime.utc(2000),
          ),
        ),
      ),
      refused(DataRefusalCode.invalid, 'checks nothing'),
    );
    final added = app
        .handle(
          ProjectCheckAdd(
            ProjectCheck(
              id: 'c1',
              repositoryId: 'r1',
              name: ' tests ',
              command: const ['make', 'test'],
              createdAt: DateTime.utc(2000),
            ),
          ),
        )
        .value;
    expect((added.name, added.createdAt), ('tests', now));
    app.handle(const ProjectVerificationSet('r1', enabled: true));
    expect(snapshot().verified, {'r1'});
    app.handle(const ProjectCheckDelete('c1'));
    expect(snapshot().projectChecks, isEmpty);
  });

  test('resumes: one live per session, a guarded transition, an update', () {
    app.handle(ResumeSchedule(resume('res1')));
    app.handle(ResumeSchedule(resume('res2')));
    final changes = lastTold();
    expect(changes, hasLength(2));
    expect(
      ScheduledResumeDao(db).getById('res1')!.state,
      ScheduledResumeState.cancelled,
    );
    expect(
      app
          .handle(
            const ResumeTransition(
              'res2',
              from: ScheduledResumeState.pending,
              to: ScheduledResumeState.firing,
            ),
          )
          .value,
      isTrue,
    );
    expect(
      app
          .handle(
            const ResumeTransition(
              'res2',
              from: ScheduledResumeState.pending,
              to: ScheduledResumeState.firing,
            ),
          )
          .value,
      isFalse,
    );
    final ended = app
        .handle(
          ResumeUpdate(
            resume(
              'res2',
            ).copyWith(state: ScheduledResumeState.done, finishedAt: now),
          ),
        )
        .value;
    expect(ended.state, ScheduledResumeState.done);
    // The copy holds the session's last ended row.
    expect(snapshot().resumes.map((r) => r.id), containsAll(['res1', 'res2']));
  });

  test('the envelope carries the whole domain', () {
    app.handle(AutomationSave(rule()));
    final json = DataEnvelope.answer(
      1,
      const AutomationsList(),
      app.handle(const AutomationsList()),
    );
    final read = DataEnvelope.readAnswer(json, const AutomationsList());
    expect(read.value.automations.single.schedule.cron, '0 3 * * *');
  });
}
