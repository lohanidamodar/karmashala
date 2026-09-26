import 'dart:io';
import 'package:karmashala_automations/store.dart';

import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/karmashala_automations.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_verification/command_checks.dart';
import 'package:karmashala_verification/artifacts.dart';
import 'package:karmashala_verification/store.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:test/test.dart';

import 'service_fixtures.dart';

class _Commands implements CheckCommandRunner {
  final exits = <String, CheckExecution>{};
  final ran = <String>[];
  @override
  Future<CheckExecution> execute(
    ProjectCheck check, {
    required EnvironmentPath directory,
    required String title,
  }) async {
    ran.add('${check.name} in ${directory.path}');
    return exits[check.name] ?? const CheckExecution.ran(exitCode: 0);
  }
}

void main() {
  late AppDatabase db;
  late Directory artifacts;
  late AutomationDao dao;
  late _Commands commands;
  late ProjectCheckRunner runner;
  var changes = 0;
  var ids = 0;

  setUp(() {
    db = fixtureDatabase();
    artifacts = Directory.systemTemp.createTempSync('check-runner');
    dao = AutomationDao(db);
    dao.insert(fixtureAutomation(armedAt: fixtureTime));
    for (final (id, name, argv) in [
      ('c1', 'tests', ['make', 'test']),
      ('c2', 'analyze', ['make', 'analyze']),
    ]) {
      ProjectCheckDao(db).insert(
        ProjectCheck(
          id: id,
          repositoryId: 'r1',
          name: name,
          command: argv,
          createdAt: fixtureTime.add(Duration(seconds: id.hashCode % 7)),
        ),
      );
    }
    commands = _Commands();
    runner = ProjectCheckRunner(
      automations: dao,
      checks: ProjectCheckDao(db),
      facts: FakeCheckoutFacts(),
      commands: commands,
      recorder: CommandCheckRecorder(
        StoreVerificationRecords(VerificationDao(db)),
        VerificationArtifactStore(artifacts),
        newId: () => 'vr-${++ids}',
        now: () => fixtureTime,
      ),
      now: () => fixtureTime,
      onChanged: () => changes++,
    );
  });
  tearDown(() {
    db.close();
    artifacts.deleteSync(recursive: true);
  });

  AutomationRun run() {
    final run = AutomationRun(
      id: 'run1',
      automationId: 'auto1',
      scheduledFor: fixtureTime,
      firedAt: fixtureTime,
      state: AutomationRunState.finished,
      reason: '',
      sessionId: 's1',
    );
    dao.insertRun(run);
    return run;
  }

  test('each check is Karmashala\'s own reading, against the run\'s '
      'session', () async {
    commands.exits['analyze'] = const CheckExecution.ran(
      exitCode: 3,
      tail: ['2 issues found'],
    );
    await runner.recordRun(run());
    final verdicts = dao.checksFor('run1');
    expect(verdicts.map((v) => v.verdict), {
      VerificationVerdict.pass,
      VerificationVerdict.fail,
    });
    for (final verdict in verdicts) {
      final recorded = VerificationDao(db).getRun(verdict.verificationRunId!)!;
      expect(recorded.attribution, VerdictAttribution.app);
      expect(recorded.sessionId, 's1');
    }
    expect(dao.runById('run1')!.checksObservedAt, fixtureTime);
    expect(commands.ran, everyElement(endsWith('/src/r1')));
    expect(changes, greaterThan(0));
  });

  test('a check that could not run is inconclusive, never a pass', () async {
    commands.exits['tests'] = const CheckExecution.refused('no pane');
    await runner.recordRun(run());
    final tests = dao.checksFor('run1').firstWhere((v) => v.name == 'tests');
    expect(tests.verdict, VerificationVerdict.inconclusive);
    expect(tests.verificationRunId, isNull);
  });

  test('checks nobody could run are recorded as not run', () {
    runner.recordNotRun(run(), 'the app is not running');
    final verdicts = dao.checksFor('run1');
    expect(verdicts, hasLength(2));
    expect(
      verdicts.map((v) => v.verdict),
      everyElement(VerificationVerdict.inconclusive),
    );
    expect(verdicts.first.reason, contains('the app is not running'));
  });

  test('a session\'s checks are one run, the worst of them', () async {
    insertSession(db, 's1');
    commands.exits['tests'] = const CheckExecution.ran(exitCode: 1);
    final result = await runner.runForSession(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Work',
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: fixtureTime,
      ),
      const EnvironmentPath(environmentId: 'local', path: '/src/r1'),
    );
    expect(result!.checks, hasLength(2));
    expect(result.run.verdict, VerificationVerdict.fail);
    expect(result.run.producedBySessionId, kAppVerifierId);
    expect(sessionChecksReport(result), startsWith('FAIL'));
    expect(sessionChecksReport(null), startsWith('NOTHING WAS CHECKED'));
  });
}
