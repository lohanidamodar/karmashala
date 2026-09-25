import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/karmashala_automations.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_session/session.dart'
    show SessionEnding, SessionStatus;
import 'package:karmashala_session_engine/karmashala_session_engine.dart'
    show SessionDao, hostSessionIdOf;
import 'package:karmashala_store/database.dart';
import 'package:karmashala_verification/store.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:test/test.dart';

Future<void> pump() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Records the base it was asked for and takes none: git is not on trial here.
class _NoCheckpoints implements RunBaseCheckpoint {
  final taken = <String>[];
  @override
  Future<String?> capture(
    EnvironmentPath checkout, {
    required String runId,
    required String label,
  }) async {
    taken.add(runId);
    return 'cp-$runId';
  }
}

void main() {
  // 03:05 local on the day a nightly 03:00 automation is due.
  final due = DateTime(2026, 9, 25, 3);
  late DateTime now;
  late AppDatabase db;
  late Directory data;
  late FakePtyLauncher launcher;
  late SessionRegistry registry;
  late HostServer server;
  late SessionStatusRecording recording;
  late ManualAutomationTimer timer;
  late DaemonAutomations automations;
  late _NoCheckpoints checkpoints;
  late List<HostMessage> toApp;
  var announced = 0;
  var ids = 0;

  AutomationDao automationDao() => AutomationDao(db);

  setUp(() {
    now = due.add(const Duration(minutes: 5)).toUtc();
    ids = 0;
    announced = 0;
    toApp = [];
    db = AppDatabase.memory();
    db.execute('PRAGMA foreign_keys = OFF;');
    data = Directory.systemTemp.createTempSync('daemon-automations');
    final at = DateTime.utc(2026, 9, 1).toIso8601String();
    for (final (id, kind) in [('local', 'localPosix'), ('box', 'ssh')]) {
      db.execute(
        'INSERT INTO execution_environments (id, kind, name, created_at) '
        'VALUES (?, ?, ?, ?);',
        [id, kind, id == 'box' ? 'the build box' : 'this machine', at],
      );
    }
    for (final (id, env) in [('r1', 'local'), ('r2', 'box')]) {
      db.execute(
        'INSERT INTO repositories '
        '(id, project_id, name, environment_id, path, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?);',
        [id, 'p1', 'repo-$id', env, '/src/$id', at],
      );
      ProjectCheckDao(db)
        ..setVerificationEnabled(id, enabled: true, now: now)
        ..insert(
          ProjectCheck(
            id: 'check-$id',
            repositoryId: id,
            name: 'the tests',
            command: const ['make', 'test'],
            createdAt: now,
          ),
        );
    }
    db.execute(
      'INSERT INTO agent_installations '
      '(id, agent_kind, environment_id, executable_path, created_at, '
      'executable_by_user) VALUES (?, ?, ?, ?, ?, 0);',
      ['a1', AgentIds.claudeCode, 'local', '/usr/local/bin/claude', at],
    );

    launcher = FakePtyLauncher();
    registry = SessionRegistry(launcher: launcher, clock: () => now);
    server = HostServer(
      registry: registry,
      ptyLibrary: 'libc',
      clock: () => now,
    );
    recording = SessionStatusRecording(server.lifecycle, db, clock: () => now)
      ..start();
    timer = ManualAutomationTimer();
    checkpoints = _NoCheckpoints();
  });

  tearDown(() async {
    await automations.close();
    await recording.close();
    db.close();
    data.deleteSync(recursive: true);
  });

  Future<void> startDaemon() async {
    automations = DaemonAutomations(
      database: db,
      registry: registry,
      dataDirectory: data.path,
      mcp: SessionMcpAccessPoint(mcp: null, configDirectory: data.path),
      announce: () => announced++,
      clock: () => now,
      newId: () => 'id-${++ids}',
      timer: timer,
      windows: false,
      checkpoints: checkpoints,
      hostEnvironment: const {'CLAUDECODE': '1', 'PATH': '/usr/bin'},
      firstRunPromptInterval: const Duration(milliseconds: 5),
    );
    await automations.start(recording.changes);
    await pump();
  }

  void nightly({String repositoryId = 'r1', DateTime? armedAt}) =>
      automationDao().insert(
        Automation(
          id: 'auto-$repositoryId',
          repositoryId: repositoryId,
          name: 'Nightly sweep',
          schedule: const AutomationSchedule.cron('0 3 * * *'),
          agentInstallationId: 'a1',
          prompt: 'Fix what broke.',
          permissionMode: const PermissionSelection({
            'mode': 'bypassPermissions',
          }),
          enabled: true,
          armedAt: armedAt ?? due.subtract(const Duration(hours: 2)).toUtc(),
        ),
      );

  List<AutomationRun> runs([String id = 'auto-r1']) =>
      automationDao().runsFor(id);

  group('missed while the host was down', () {
    test('inside the grace it fires once on start, as a session the host '
        'owns', () async {
      nightly();
      await startDaemon();

      final run = runs().single;
      expect(run.state, AutomationRunState.running);
      expect(run.baseCheckpointId, 'cp-${run.id}');
      final sessionId = run.sessionId!;
      final spawn = launcher.started.single;
      expect(registry.find(hostSessionIdOf(sessionId)), isNotNull);
      // The launch spec came from the descriptor, never from an id branch.
      expect(spawn.argv.first, '/usr/local/bin/claude');
      expect(spawn.argv, containsAllInOrder(['--session-id', sessionId]));
      expect(
        spawn.argv,
        containsAllInOrder(['--permission-mode', 'bypassPermissions']),
      );
      expect(spawn.argv.last, 'Fix what broke.');
      expect(spawn.workingDirectory, '/src/r1');
      expect(spawn.environment['KARMASHALA_SESSION_ID'], sessionId);
      // A parent Claude session's markers are never inherited.
      expect(spawn.removedEnvironment, contains('CLAUDECODE'));

      final row = db.query('SELECT * FROM sessions WHERE id = ?;', [
        sessionId,
      ]).single;
      expect(row['status'], 'running');
      expect(row['external_session_id'], sessionId);
      expect(announced, greaterThan(0));

      // A second sweep does not fire the same occurrence again.
      await automations.scheduler.reconcile();
      expect(runs(), hasLength(1));
      expect(launcher.started, hasLength(1));
    });

    test(
      'beyond the grace it is recorded as missed, and nothing starts',
      () async {
        now = due.add(const Duration(hours: 2)).toUtc();
        nightly();
        await startDaemon();

        final run = runs().single;
        expect(run.state, AutomationRunState.missed);
        expect(run.reason, contains('was not running'));
        expect(launcher.started, isEmpty);
      },
    );

    test('the one timer is armed for the next occurrence', () async {
      now = due.subtract(const Duration(hours: 1)).toUtc();
      nightly();
      await startDaemon();
      expect(runs(), isEmpty);
      expect(timer.armedFor, const Duration(hours: 1));
    });
  });

  group('a run the host started', () {
    test('its session ending settles it, then the checks run in a session the '
        'host owns and the verdict is Karmashala\'s', () async {
      nightly();
      await startDaemon();
      final run = runs().single;
      launcher.handles.single.finish(0);
      await pump();

      expect(runs().single.state, AutomationRunState.finished);
      final check = launcher.started.last;
      expect(check.argv, ['make', 'test']);
      expect(check.workingDirectory, '/src/r1');
      expect(
        registry.sessions.where((s) => s.id.startsWith(kCheckSessionPrefix)),
        hasLength(1),
      );
      launcher.handles.last
        ..emit('All 12 tests passed\r\n'.codeUnits)
        ..finish(0);
      await pump();
      // The evidence file is real disk I/O.
      await automations.checks.drain();
      await pump();

      final verdict = automationDao().checksFor(run.id).single;
      expect(verdict.verdict, VerificationVerdict.pass);
      final recorded = VerificationDao(db).getRun(verdict.verificationRunId!)!;
      expect(recorded.producedBySessionId, kAppVerifierId);
      expect(recorded.attribution, VerdictAttribution.app);
      expect(recorded.sessionId, run.sessionId);
      expect(automationDao().runById(run.id)!.checksObservedAt, isNotNull);
      // The check's session is let go once its verdict is taken.
      expect(
        registry.sessions.where((s) => s.id.startsWith(kCheckSessionPrefix)),
        isEmpty,
      );
    });

    test('an interval is re-armed from the run\'s finish', () async {
      automationDao().insert(
        Automation(
          id: 'auto-r1',
          repositoryId: 'r1',
          name: 'Every half hour',
          schedule: AutomationSchedule.every(const Duration(minutes: 30)),
          agentInstallationId: 'a1',
          prompt: 'Look again.',
          permissionMode: const PermissionSelection({
            'mode': 'bypassPermissions',
          }),
          enabled: true,
          armedAt: now.subtract(const Duration(minutes: 31)),
        ),
      );
      await startDaemon();
      expect(runs().single.state, AutomationRunState.running);
      // While it runs an interval has no next occurrence at all.
      expect(timer.isArmed, isFalse);

      now = now.add(const Duration(minutes: 7));
      launcher.handles.first.finish(0);
      await pump();
      expect(runs().single.state, AutomationRunState.finished);
      expect(timer.armedFor, const Duration(minutes: 30));
    });

    test('a failed exit fails the run and its budget', () async {
      nightly();
      await startDaemon();
      launcher.handles.single.finish(1);
      await pump();
      expect(runs().single.state, AutomationRunState.failed);
      expect(automationDao().getById('auto-r1')!.consecutiveFailures, 1);
    });

    // Found live: `session_end` closed the run's session; the exit the signal
    // caused (143) was read as the agent failing, and the run settled on it.
    test('its session closed on request settles it as stopped by you, and '
        'spends no budget', () async {
      nightly();
      await startDaemon();
      final run = runs().single;
      final statuses = <String>[];
      final watching = recording.changes.listen(
        (change) => statuses.add(change.to.name),
      );
      addTearDown(watching.cancel);

      final closing = registry.close(hostSessionIdOf(run.sessionId!));
      await pump();
      launcher.handles.first.finish(143);
      await closing;
      await pump();

      final settled = runs().single;
      expect(
        settled.state,
        AutomationRunSettler.stateOfEnding(SessionEnding.cancelled),
      );
      expect(settled.reason, contains('was stopped by you'));
      expect(settled.reason, isNot(contains('stopped in error')));
      expect(statuses, ['cancelled'], reason: 'never failed on the way');
      final automation = automationDao().getById('auto-r1')!;
      expect(automation.consecutiveFailures, 0);
      expect(automation.enabled, isTrue);
    });

    // Found live: SIGTERM to the host killed its sessions on the way out, and
    // each exit (143) was written as the agent failing.
    test('its session ended by the host shutting down is never failed, and '
        'spends no budget', () async {
      nightly();
      await startDaemon();
      final run = runs().single;
      final statuses = <String>[];
      final watching = recording.changes.listen(
        (change) => statuses.add(change.to.name),
      );
      addTearDown(watching.cancel);

      final stopping = registry.shutdown();
      await pump();
      launcher.handles.first.finish(143);
      await stopping;
      await pump();

      final session = registry.find(hostSessionIdOf(run.sessionId!))!;
      expect(session.lifecycle.exitCode, isNull);
      expect(
        session.lifecycle.describe(),
        contains(SessionEndedWithoutCode.hostStopped),
      );
      expect(statuses, ['unknown'], reason: 'never failed on the way');
      expect(
        SessionDao(db).getById(run.sessionId!)!.status,
        SessionStatus.unknown,
      );
      // Losing the process with its host is no verdict on the automation.
      expect(runs().single.state, AutomationRunState.running);
      final automation = automationDao().getById('auto-r1')!;
      expect(automation.consecutiveFailures, 0);
      expect(automation.enabled, isTrue);
    });
  });

  group('an agent stopped at its first-run question', () {
    /// Claude Code's folder-trust question as it draws it — the wording of
    /// `claude-code-trust-prompt.raw`, seen live under an unwatched run.
    const trustQuestion =
        ' Accessing workspace:\r\n\r\n /src/r1\r\n\r\n'
        ' Quick safety check: Is this a project you created or one you trust?'
        ' (Like your\r\n own code, a well-known open source project, or work '
        'from your team).\r\n\r\n'
        ' \u276f 1. No, exit\r\n   2. Yes, I trust this folder\r\n\r\n'
        ' Enter to confirm \u00b7 Esc to cancel\r\n';

    Future<void> waitFor(bool Function() done) async {
      for (var i = 0; i < 200 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    test('fails the run with the reason, and leaves the agent at the '
        'question', () async {
      nightly();
      await startDaemon();
      final agent = launcher.handles.single;
      agent.emit(_utf8(trustQuestion));

      await waitFor(() => runs().single.state != AutomationRunState.running);

      final run = runs().single;
      expect(run.state, AutomationRunState.failed);
      expect(
        run.reason,
        startsWith(
          'Claude Code is asking whether to trust /src/r1, and nobody is '
          'there to answer. Open the session once and answer it, then the '
          'automation can run unattended.',
        ),
      );
      // Never answered on the person's behalf, and never killed.
      expect(agent.writes, isEmpty);
      expect(agent.signals, isEmpty);
      final row = db.query('SELECT status FROM sessions WHERE id = ?;', [
        run.sessionId,
      ]).single;
      expect(row['status'], 'running');
      expect(automations.firstRunPrompts.watching, isEmpty);
      expect(automationDao().getById('auto-r1')!.consecutiveFailures, 1);
    });

    test('an agent getting on with it is left running', () async {
      nightly();
      await startDaemon();
      launcher.handles.single.emit(
        _utf8('\u23fa Reading the failing tests\r\n esc to interrupt\r\n'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(runs().single.state, AutomationRunState.running);
      expect(automations.firstRunPrompts.watching, hasLength(1));
      // Its session ending stops the watch.
      launcher.handles.single.finish(0);
      await waitFor(() => automations.firstRunPrompts.watching.isEmpty);
      expect(automations.firstRunPrompts.watching, isEmpty);
    });
  });

  group('a checkout only the app can start in', () {
    test('with no app it is missed, and says why', () async {
      nightly(repositoryId: 'r2');
      await startDaemon();
      final run = runs('auto-r2').single;
      expect(run.state, AutomationRunState.missed);
      expect(run.reason, contains('the build box'));
      expect(run.reason, contains('app was not running'));
      expect(launcher.started, isEmpty);
    });

    test('with the app connected it is forwarded to it', () async {
      now = due.subtract(const Duration(minutes: 1)).toUtc();
      nightly(repositoryId: 'r2');
      await startDaemon();
      final app = Object();
      automations.notice(
        app,
        const AutomationNoticeMessage(AutomationNoticeKind.ready),
        toApp.add,
      );
      now = due.add(const Duration(seconds: 5)).toUtc();
      timer.fire();
      await pump();

      final call = toApp.whereType<AutomationCallMessage>().single;
      expect(call.kind, AutomationCallKind.fireAutomation);
      expect(call.id, 'auto-r2');
      expect(call.scheduledFor, due.toUtc());
      automations.answer(app, AutomationResultMessage.success(call.callId));
      await pump();
      // The app writes the run; the host records nothing of its own.
      expect(runs('auto-r2'), isEmpty);
      expect(launcher.started, isEmpty);
    });
  });

  group('a scheduled resume', () {
    void armResume() {
      db.execute(
        'INSERT INTO sessions (id, repository_id, agent_installation_id, '
        'title, use_worktree, status, created_at) '
        "VALUES ('s1', 'r1', 'a1', 'Work', 0, 'completed', ?);",
        [DateTime.utc(2026, 9, 24).toIso8601String()],
      );
      ScheduledResumeDao(db).replaceFor(
        ScheduledResume(
          id: 'resume1',
          sessionId: 's1',
          fireAt: now.subtract(const Duration(minutes: 1)),
          state: ScheduledResumeState.pending,
          scheduledAt: now.subtract(const Duration(hours: 1)),
          message: 'continue',
        ),
        now: now,
      );
    }

    test('with no app it waits for one, and goes when one arrives', () async {
      armResume();
      await startDaemon();
      final waiting = ScheduledResumeDao(db).getById('resume1')!;
      expect(waiting.state, ScheduledResumeState.queued);
      expect(waiting.reason, kResumeWaitingForApp);

      automations.notice(
        Object(),
        const AutomationNoticeMessage(AutomationNoticeKind.ready),
        toApp.add,
      );
      await pump();
      final call = toApp.whereType<AutomationCallMessage>().single;
      expect(call.kind, AutomationCallKind.fireResume);
      expect(call.id, 'resume1');
    });

    test('an app that arrives too late for it records the miss', () async {
      armResume();
      await startDaemon();
      now = now.add(const Duration(hours: 1));
      automations.notice(
        Object(),
        const AutomationNoticeMessage(AutomationNoticeKind.ready),
        toApp.add,
      );
      await pump();
      expect(toApp.whereType<AutomationCallMessage>(), isEmpty);
      final missed = ScheduledResumeDao(db).getById('resume1')!;
      expect(missed.state, ScheduledResumeState.missed);
      expect(missed.reason, contains('app was not running'));
    });
  });

  group('checks asked for by name', () {
    void session(String id, String repositoryId) => db.execute(
      'INSERT INTO sessions (id, repository_id, agent_installation_id, '
      'title, use_worktree, status, created_at) '
      "VALUES (?, ?, 'a1', 'Work', 0, 'running', ?);",
      [id, repositoryId, DateTime.utc(2026, 9, 24).toIso8601String()],
    );

    test(
      'checks_run for a checkout here runs in the host and says so',
      () async {
        session('s1', 'r1');
        await startDaemon();
        final answer = automations.localTool('checks_run', const {}, 's1')!;
        await pump();
        launcher.handles.last.finish(2);
        final text = await answer as String;
        expect(text, startsWith('FAIL'));
        expect(text, contains('FAIL (exit 2) the tests (make test)'));
        final run = VerificationDao(db).listRuns(limit: 1).single;
        expect(run.producedBySessionId, kAppVerifierId);
        expect(run.sessionId, 's1');
      },
    );

    test('a command that cannot be found is said so, never an exit '
        'nobody saw', () async {
      session('s1', 'r1');
      await startDaemon();
      launcher.failWith = const PtyException(
        '"make" was not found on PATH (/usr/bin:/bin)',
      );
      final text =
          await automations.localTool('checks_run', const {}, 's1')! as String;
      expect(text, contains('"make" was not found on PATH (/usr/bin:/bin)'));
      expect(text, isNot(contains('exit 127')));
    });

    test('checks_run for a checkout elsewhere is handed to the app', () async {
      session('s2', 'r2');
      await startDaemon();
      expect(automations.localTool('checks_run', const {}, 's2'), isNull);
      expect(automations.localTool('session_list', const {}, 's1'), isNull);
    });

    test('the app asking by frame gets the verification run', () async {
      session('s1', 'r1');
      await startDaemon();
      final answer = automations.runChecks(
        const ChecksRunMessage(requestId: 7, sessionId: 's1'),
      );
      await pump();
      launcher.handles.last.finish(0);
      final ran = await answer;
      expect(ran.requestId, 7);
      expect(ran.outcome, ChecksRunOutcome.ran);
      expect(
        VerificationDao(db).getRun(ran.verificationRunId!)!.verdict,
        VerificationVerdict.pass,
      );

      final elsewhere = await automations.runChecks(
        const ChecksRunMessage(requestId: 8, sessionId: 'nobody'),
      );
      expect(elsewhere.outcome, ChecksRunOutcome.failed);
    });
  });
}

List<int> _utf8(String text) => utf8.encode(text);
