import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/automations/application/automation_providers.dart';
import 'package:karmashala/src/features/automations/application/automation_runner.dart';
import 'package:karmashala_automations/persistence.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala/src/features/checkpoints/application/checkpoint_providers.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import '../../support/workspace_mirror.dart';

/// Records what it was asked to capture, and captures nothing.
class _FakeCheckpoints extends CheckpointService {
  _FakeCheckpoints(AppDatabase db)
    : super(
        runnerFactory: const CommandRunnerFactory(),
        environmentOf: mirroredServer(db).environmentRows.getById,
        dao: CheckpointDao(db),
        clock: FixedClock(testTime),
        newId: () => 'cp1',
      );

  final List<({EnvironmentPath repo, String sessionId, bool evenIfUnchanged})>
  captures = [];

  /// Set to throw instead, for the "nothing to undo it with" case.
  Object? failure;

  @override
  Future<Checkpoint?> capture(
    EnvironmentPath repo, {
    required String sessionId,
    CheckpointReason reason = CheckpointReason.turn,
    String? label,
    bool evenIfUnchanged = false,
    int? turn,
    String? prompt,
  }) async {
    if (failure != null) throw failure!;
    captures.add((
      repo: repo,
      sessionId: sessionId,
      evenIfUnchanged: evenIfUnchanged,
    ));
    return Checkpoint(
      id: 'cp1',
      sessionId: sessionId,
      repository: repo,
      sequence: 1,
      treeSha: 'tree',
      commitSha: 'commit',
      parentCommitSha: null,
      headSha: 'head',
      reason: reason,
      createdAt: testTime,
      label: label,
    );
  }
}

/// Records the launch request and starts nothing.
class _FakeLauncher extends SessionLauncher {
  _FakeLauncher(super.ref);

  final List<SessionLaunchRequest> requests = [];
  Object? failure;

  @override
  Future<SessionLaunchResult> launch(
    SessionLaunchRequest request, {
    SystemTerminal? externalTerminal,
  }) async {
    if (failure != null) throw failure!;
    requests.add(request);
    return SessionLaunchResult(session: session(id: 'started'));
  }
}

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late _FakeCheckpoints checkpoints;
  late _FakeLauncher launcher;

  final due = DateTime.utc(2026, 9, 9, 3);

  Automation automation({PermissionSelection? mode}) => Automation(
    id: 'auto1',
    repositoryId: 'r1',
    name: 'Nightly sweep',
    schedule: const AutomationSchedule.cron('0 3 * * *'),
    agentInstallationId: 'a1',
    prompt: 'Run the checks and fix what broke.',
    permissionMode: mode ?? const PermissionSelection({'mode': 'auto'}),
    enabled: true,
    armedAt: testTime,
  );

  void makeReady() {
    container
        .read(projectCheckDaoProvider)
        .setVerificationEnabled('r1', enabled: true, now: testTime);
    container.read(automationControllerProvider).addCheck(
      'r1',
      'the test suite',
      const ['flutter', 'test'],
    );
  }

  AutomationRun theRun() => AutomationDao(db).runsFor('auto1').single;

  setUp(() async {
    db = AppDatabase.memory();
    final server = FakeDataServer()..mirrorInto(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(agentId: AgentIds.claudeCode),
    );
    AutomationDao(db).insert(automation());
    checkpoints = _FakeCheckpoints(db);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('run-')),
        checkpointServiceProvider.overrideWithValue(checkpoints),
        sessionLauncherProvider.overrideWith((ref) => _FakeLauncher(ref)),
      ],
    );
    launcher = container.read(sessionLauncherProvider) as _FakeLauncher;
    addTearDown(container.dispose);
    addTearDown(db.close);
  });

  AutomationRunner runner() => container.read(automationRunnerProvider);

  group('the gate runs again at fire time', () {
    test(
      'a refusal is a recorded failure carrying the refusal\'s own words',
      () async {
        // Nothing was configured: the arming-time precondition is absent now.
        await runner().fire(automation(), due);
        final run = theRun();
        expect(run.state, AutomationRunState.failed);
        expect(run.reason, contains('Verification is off for app'));
        expect(run.scheduledFor, due);
        expect(run.finishedAt, isNotNull);
        // Nothing was captured and nothing was started.
        expect(checkpoints.captures, isEmpty);
        expect(launcher.requests, isEmpty);
      },
    );

    test(
      'a refused fire is still recorded, so the occurrence is not re-found',
      () async {
        await runner().fire(automation(), due);
        expect(AutomationDao(db).lastObservedOccurrence('auto1'), due);
      },
    );

    test('a mode that would prompt is refused at fire time too', () async {
      makeReady();
      await runner().fire(
        automation(mode: const PermissionSelection({'mode': 'manual'})),
        due,
      );
      expect(theRun().state, AutomationRunState.failed);
      expect(theRun().reason, contains('nobody there to answer'));
      expect(launcher.requests, isEmpty);
    });
  });

  group('a permitted fire', () {
    setUp(makeReady);

    test('records the base before the agent touches anything', () async {
      await runner().fire(automation(), due);
      final capture = checkpoints.captures.single;
      expect(
        capture.repo,
        const EnvironmentPath(
          environmentId: 'windows',
          path: r'C:\src\demo\app',
        ),
      );
      // Keyed by the run, not by a session — the session does not exist yet.
      expect(capture.sessionId, theRun().id);
      // A run with no base is a run that cannot be taken back.
      expect(capture.evenIfUnchanged, isTrue);
      expect(theRun().baseCheckpointId, 'cp1');
    });

    test(
      'starts the session with the prompt, in the automation\'s mode',
      () async {
        await runner().fire(automation(), due);
        final request = launcher.requests.single;
        expect(request.firstMessage, 'Run the checks and fix what broke.');
        expect(request.title, 'Nightly sweep');
        expect(request.purpose, SessionPurpose.newSession);
        expect(request.permissionOverride?.canonical, 'mode=auto');
        expect(request.repository.id, 'r1');
        expect(request.installation.id, 'a1');
      },
    );

    test('the run is running, and names the session', () async {
      await runner().fire(automation(), due);
      final run = theRun();
      expect(run.state, AutomationRunState.running);
      expect(run.sessionId, 'started');
      expect(run.finishedAt, isNull);
    });

    test('a mode nobody chose is left to the agent\'s own default', () async {
      // Claude Code's declared default asks, so the gate refuses it — which is
      // the point: "nobody chose" is not a way past the rule, it means "use
      // this agent's declared default" and that default is read like any other.
      final unchosen = Automation(
        id: 'auto1',
        repositoryId: 'r1',
        name: 'Nightly sweep',
        schedule: const AutomationSchedule.cron('0 3 * * *'),
        agentInstallationId: 'a1',
        prompt: 'Run the checks.',
        permissionMode: null,
        enabled: true,
        armedAt: testTime,
      );
      await runner().fire(unchosen, due);
      expect(theRun().state, AutomationRunState.failed);
      expect(theRun().reason, contains('nobody there to answer'));
    });

    test(
      'a base that could not be recorded stops the run before it starts',
      () async {
        checkpoints.failure = StateError('git said no');
        await runner().fire(automation(), due);
        expect(theRun().state, AutomationRunState.failed);
        expect(theRun().reason, contains('nothing to undo it with'));
        expect(launcher.requests, isEmpty);
      },
    );

    test(
      'a launch that failed is a recorded failure, not a silent one',
      () async {
        launcher.failure = const SessionLaunchRefused(
          'takes no opening message',
        );
        await runner().fire(automation(), due);
        expect(theRun().state, AutomationRunState.failed);
        expect(theRun().reason, contains('takes no opening message'));
        expect(theRun().finishedAt, isNotNull);
      },
    );
  });

  test(
    'a drained queue entry becomes the run rather than a second row',
    () async {
      makeReady();
      final waiting = AutomationRun(
        id: 'waiting',
        automationId: 'auto1',
        scheduledFor: due,
        firedAt: testTime,
        state: AutomationRunState.queued,
        reason: 'This checkout is busy.',
      );
      AutomationDao(db).insertRun(waiting);
      await runner().fire(
        automation(),
        due,
        note: 'started when it came free',
        queued: waiting,
      );
      final runs = AutomationDao(db).runsFor('auto1');
      expect(runs, hasLength(1));
      expect(runs.single.id, 'waiting');
      expect(runs.single.state, AutomationRunState.running);
      expect(runs.single.reason, 'started when it came free');
    },
  );
}
