import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/karmashala_automations.dart';
import 'package:karmashala_automations/store.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'service_fixtures.dart';

class _Checkpoints implements RunBaseCheckpoint {
  final taken = <EnvironmentPath>[];

  @override
  Future<String?> capture(
    EnvironmentPath checkout, {
    required String runId,
    required String label,
  }) async {
    taken.add(checkout);
    return 'base-of-$runId';
  }
}

class _NoLauncher implements AutomationSessionLauncher {
  @override
  Future<String> launch(
    Automation automation,
    Repository repository,
    AgentInstallation installation, {
    PullRequestCheckout? pullRequest,
  }) => throw StateError('a command run starts no agent');
}

class _Commands implements StepCommandRunner {
  StepCommandResult answer = const StepCommandResult(
    exitCode: 0,
    output: 'ok\n',
  );
  Object? failWith;
  final calls =
      <
        ({
          Automation automation,
          String command,
          Map<String, String> environment,
          Duration timeout,
        })
      >[];

  @override
  Future<StepCommandResult> run(
    Automation automation,
    AutomationRun run, {
    required String command,
    required Map<String, String> environment,
    required Duration timeout,
  }) async {
    calls.add((
      automation: automation,
      command: command,
      environment: environment,
      timeout: timeout,
    ));
    if (failWith != null) throw failWith!;
    return answer;
  }
}

/// A command as an automation's first step: run with no agent, its exit code
/// and output kept on the run, a non-zero exit or a timeout a failure that
/// counts, and values reaching it only as its environment.
void main() {
  const hostile = r'x"; rm -rf ~; echo "$(whoami)` & calc';
  late AppDatabase db;
  late AutomationDao dao;
  late FakeCheckoutFacts facts;
  late _Checkpoints checkpoints;
  late _Commands commands;
  late AutomationRunner runner;
  late List<String> notified;
  var ids = 0;

  setUp(() {
    db = fixtureDatabase();
    dao = AutomationDao(db);
    facts = FakeCheckoutFacts()..agent = null;
    checkpoints = _Checkpoints();
    commands = _Commands();
    notified = [];
    final followUps = AutomationFollowUps(
      automations: dao,
      resumes: ScheduledResumeDao(db),
      repositoryName: (_) => 'repo',
      notify: (automation, run, text, {required failed}) => notified.add(text),
      now: () => fixtureTime,
      newId: () => 'note-${++ids}',
    );
    final settler = AutomationRunSettler(
      automations: dao,
      sessionOf: (_) => null,
      runChecks: followUps.after,
      drain: (_) async {},
      now: () => fixtureTime,
    );
    runner = AutomationRunner(
      automations: dao,
      preflight: UnattendedPreflight(facts: facts),
      facts: facts,
      checkpoints: checkpoints,
      launcher: _NoLauncher(),
      now: () => fixtureTime,
      newId: () => 'run-${++ids}',
      commands: commands,
      finish: settler.finish,
    );
  });
  tearDown(() => db.close());

  Automation command({
    AutomationSteps steps = AutomationSteps.none,
    int stopAfterFailures = kDefaultStopAfterFailures,
    EnvironmentPath? folder,
    Duration? maxRuntime,
  }) {
    final automation = fixtureAutomation(armedAt: fixtureTime).copyWith(
      agentInstallationId: '',
      prompt: '',
      command: const AutomationCommand(text: 'make sync'),
      folder: folder,
      repositoryId: folder == null ? 'r1' : '',
      steps: steps,
      stopAfterFailures: stopAfterFailures,
      maxRuntime: maxRuntime,
    );
    dao.insert(automation);
    return automation;
  }

  Future<AutomationRun> fired(Automation automation) async {
    final run = await runner.start(
      automation,
      fixtureTime,
      variables: const {'github.comment.body': hostile},
    );
    await pumpEventQueue();
    return dao.runById(run.id)!;
  }

  test('an exit of 0 finishes the run, keeping what it printed', () async {
    final run = await fired(command());
    expect(run.state, AutomationRunState.finished);
    expect(run.exitCode, 0);
    expect(run.output, 'ok\n');
    expect(run.reason, 'It exited with 0.');
    expect(run.sessionId, isNull);
    // In a checkout it is checkpointed first, so it can be undone.
    expect(run.baseCheckpointId, 'base-of-${run.id}');
  });

  test('a non-zero exit fails the run, and counts toward pausing it', () async {
    commands.answer = const StepCommandResult(exitCode: 3, output: 'nope');
    final run = await fired(command(stopAfterFailures: 1));
    expect(run.state, AutomationRunState.failed);
    expect(run.exitCode, 3);
    expect(run.reason, 'It exited with 3.');
    final after = dao.getById('auto1')!;
    expect(after.consecutiveFailures, 1);
    expect(after.enabled, isFalse, reason: 'it failed out');
    expect(after.disabledReason, contains('failed runs in a row'));
  });

  test(
    'a command still running at its time limit is stopped, and fails',
    () async {
      commands.answer = const StepCommandResult(
        exitCode: null,
        output: 'half',
        timedOut: true,
      );
      final run = await fired(command(maxRuntime: const Duration(minutes: 5)));
      expect(commands.calls.single.timeout, const Duration(minutes: 5));
      expect(run.state, AutomationRunState.failed);
      expect(run.exitCode, isNull);
      expect(run.reason, 'Stopped after 5m, its time limit.');
    },
  );

  test('with no longest run it still has a time limit', () async {
    await fired(command());
    expect(commands.calls.single.timeout, kCommandTimeLimit);
  });

  test('values reach it as environment variables, never in its text', () async {
    await fired(command());
    final call = commands.calls.single;
    expect(call.command, 'make sync');
    expect(call.environment['KARMASHALA_GITHUB_COMMENT_BODY'], hostile);
    expect(call.environment['KARMASHALA_AUTOMATION'], 'Nightly');
    expect(call.environment['KARMASHALA_PROJECT'], 'repo');
  });

  test('a command that cannot start fails the run with why', () async {
    commands.failWith = StateError('no such folder');
    final run = await fired(command());
    expect(run.state, AutomationRunState.failed);
    expect(run.reason, contains('no such folder'));
  });

  test('in a folder it needs no checkout and takes no checkpoint', () async {
    facts.repo = null;
    const notes = EnvironmentPath(environmentId: 'local', path: '~/notes');
    final run = await fired(command(folder: notes));
    expect(run.state, AutomationRunState.finished);
    expect(checkpoints.taken, isEmpty);
    expect(commands.calls.single.automation.folder, notes);
    expect(commands.calls.single.environment['KARMASHALA_PROJECT'], '~/notes');
  });

  test('a folder the server cannot reach is refused before it runs', () async {
    facts.reachable = UnattendedReach.unreachable;
    final run = await fired(
      command(
        folder: const EnvironmentPath(environmentId: 'box', path: '~'),
      ),
    );
    expect(run.state, AutomationRunState.failed);
    expect(commands.calls, isEmpty);
  });

  test(
    "the steps after it still keep their when, and read its output",
    () async {
      commands.answer = const StepCommandResult(exitCode: 2, output: 'broke');
      await fired(
        command(
          steps: AutomationSteps(const [
            AutomationStep(
              kind: AutomationStepKind.notify,
              when: AutomationStepWhen.failure,
              text: '{{steps.command.exit_code}}: {{steps.command.output}}',
            ),
          ]),
        ),
      );
      expect(notified, ['2: broke']);

      notified.clear();
      commands.answer = const StepCommandResult(exitCode: 0, output: 'fine');
      dao.update(
        dao
            .getById('auto1')!
            .copyWith(
              steps: AutomationSteps(const [
                AutomationStep(
                  kind: AutomationStepKind.notify,
                  when: AutomationStepWhen.failure,
                ),
              ]),
            ),
      );
      await fired(dao.getById('auto1')!);
      expect(notified, isEmpty, reason: 'it succeeded');
    },
  );
}
