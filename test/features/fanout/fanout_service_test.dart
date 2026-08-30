import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/core/process/command_runner_providers.dart';
import 'package:chitragupta/src/core/util/clock_provider.dart';
import 'package:chitragupta/src/core/util/id_generator_provider.dart';
import 'package:chitragupta/src/features/agents/application/agent_providers.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/agents/domain/agent_descriptor.dart';
import 'package:chitragupta/src/features/agents/domain/agent_installation.dart';
import 'package:chitragupta/src/features/agents/domain/agent_registry.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/fanout/application/fanout_service.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/sessions/data/session_dao.dart';
import 'package:chitragupta/src/features/sessions/domain/session_status.dart';
import 'package:chitragupta/src/features/settings/application/settings_controller.dart';
import 'package:chitragupta/src/features/settings/domain/permission_mode.dart';
import 'package:chitragupta/src/features/settings/domain/settings.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// Parallel worktree fan-out: run one prompt on several agents at once, compare
/// their diffs, merge one, discard the rest.
///
/// The feature shipped with no tests at all. These cover what input it refuses,
/// what it does when only *some* agents start, and what it will merge.
const _rover = AgentDescriptor(
  id: 'roverCli',
  displayName: 'Rover CLI',
  binaries: AgentBinaries(windows: ['rover'], posix: ['rover']),
  launch: AgentLaunchSpec(
    baseArguments: [],
    permissionArguments: {
      PermissionMode.ask: ['--careful'],
      PermissionMode.bypass: ['--trust-me'],
    },
    acceptsPromptArgument: true,
  ),
);

const _flaky = AgentDescriptor(
  id: 'flakyCli',
  displayName: 'Flaky CLI',
  binaries: AgentBinaries(windows: ['flaky'], posix: ['flaky']),
  launch: AgentLaunchSpec(
    baseArguments: [],
    permissionArguments: {
      PermissionMode.ask: ['--careful'],
      PermissionMode.bypass: ['--trust-me'],
    },
    acceptsPromptArgument: true,
  ),
);

AgentInstallation roverInstall = agentInstallation(
  id: 'a-rover',
  agentId: 'roverCli',
);
AgentInstallation flakyInstall = agentInstallation(
  id: 'a-flaky',
  agentId: 'flakyCli',
  path: r'C:\Users\me\.bin\flaky.exe',
);
AgentInstallation secondRoverInstall = agentInstallation(
  id: 'a-rover-2',
  agentId: 'roverCli',
  path: r'C:\Users\me\.bin\rover2.exe',
);

class _StaticSettings extends SettingsController {
  _StaticSettings(this._settings);
  final Settings _settings;
  @override
  Settings build() => _settings;
}

typedef Harness = ({
  ProviderContainer container,
  AppDatabase db,
  FakeCommandRunner git,
});

/// Builds the fan-out under a real [SessionLauncher] over fake terminals and a
/// fake git, so worktree creation, session rows and pane launch are the real
/// code paths rather than a friendlier stand-in.
Harness harness({
  /// Agent ids whose pane refuses to be created, to force a partial launch.
  Set<String> paneFailsFor = const {},
  CommandResult Function(CommandRequest request)? git,
}) {
  final db = AppDatabase.memory();
  ExecutionEnvironmentDao(db).upsert(windowsEnv());
  ProjectDao(db).insert(project());
  RepositoryDao(db).insert(repository());
  AgentInstallationDao(db)
    ..insert(roverInstall)
    ..insert(flakyInstall)
    ..insert(secondRoverInstall);

  final runner = FakeCommandRunner(
    responder:
        git ?? (_) => const CommandResult(exitCode: 0, stdout: '', stderr: ''),
  );

  final container = ProviderContainer(
    overrides: [
      ...fakeTerminalOverrides(
        database: db,
        instanceFactory: paneFailsFor.isEmpty
            ? null
            : ({
                required id,
                required profile,
                workingDirectory,
                restoredScrollback,
                shellIntegration = false,
                agentLaunch,
              }) {
                if (paneFailsFor.contains(agentLaunch?.agentId)) {
                  throw StateError('could not start ${agentLaunch?.agentId}');
                }
                return defaultFakeInstanceFactory(
                  id: id,
                  profile: profile,
                  workingDirectory: workingDirectory,
                  restoredScrollback: restoredScrollback,
                  shellIntegration: shellIntegration,
                  agentLaunch: agentLaunch,
                );
              },
      ),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      idGeneratorProvider.overrideWithValue(SequentialIdGenerator('sesid00')),
      agentRegistryProvider.overrideWithValue(
        const AgentRegistry([_rover, _flaky]),
      ),
      settingsControllerProvider.overrideWith(
        () => _StaticSettings(const Settings()),
      ),
      // Nothing here may shell out: git is faked, and the host runner is faked
      // so no path can reach a real terminal.
      commandRunnerFactoryProvider.overrideWithValue(
        FakeCommandRunnerFactory(fallback: runner),
      ),
      hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
    ],
  );
  return (container: container, db: db, git: runner);
}

void main() {
  group('validation refuses before anything is created', () {
    late Harness h;
    setUp(() => h = harness());
    tearDown(() {
      h.container.dispose();
      h.db.close();
    });

    Future<FanOutLaunch> run({
      String prompt = 'do the thing',
      List<AgentInstallation>? installations,
    }) => h.container
        .read(fanOutServiceProvider)
        .launch(
          repository: repository(),
          installations: installations ?? [roverInstall, flakyInstall],
          prompt: prompt,
        );

    test('an empty prompt is refused', () async {
      await expectLater(run(prompt: ''), throwsA(isA<ArgumentError>()));
      expect(h.git.requests, isEmpty);
      expect(SessionDao(h.db).getAll(), isEmpty);
    });

    test('a whitespace-only prompt is refused', () async {
      await expectLater(run(prompt: '   \n  '), throwsA(isA<ArgumentError>()));
      expect(h.git.requests, isEmpty);
    });

    test('fewer than two installations is not a comparison', () async {
      await expectLater(
        run(installations: [roverInstall]),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        run(installations: const []),
        throwsA(isA<ArgumentError>()),
      );
      expect(h.git.requests, isEmpty);
    });

    test('the same installation twice is refused', () async {
      await expectLater(
        run(installations: [roverInstall, roverInstall]),
        throwsA(isA<ArgumentError>()),
      );
      expect(h.git.requests, isEmpty);
    });

    test('two installations of the same agent are allowed', () async {
      final launched = await run(
        installations: [roverInstall, secondRoverInstall],
      );
      expect(launched.started, hasLength(2));
      expect(launched.failures, isEmpty);
    });
  });

  group('launch', () {
    test(
      'gives every agent its own worktree on its own session branch',
      () async {
        final h = harness();
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);

        final launched = await h.container
            .read(fanOutServiceProvider)
            .launch(
              repository: repository(),
              installations: [roverInstall, flakyInstall],
              prompt: 'refactor the parser',
            );

        expect(launched.started, hasLength(2));
        expect(launched.failures, isEmpty);
        expect(launched.hasFailures, isFalse);
        expect(launched.partialSummary, isNull);
        expect(launched.requested, 2);
        expect(launched.started.map((r) => r.agentId), [
          'roverCli',
          'flakyCli',
        ]);

        // Two worktrees, each on the branch its session names.
        final adds = h.git.requests
            .where((r) => r.arguments.contains('add'))
            .toList();
        expect(adds, hasLength(2));
        for (final result in launched.started) {
          expect(result.session.worktree, isNotNull);
          expect(
            adds.any(
              (a) => a.arguments.contains(
                'session/${result.session.id.substring(0, 8)}',
              ),
            ),
            isTrue,
            reason: 'a worktree on this session\'s branch',
          );
        }
      },
    );

    test('sends the trimmed prompt to every agent', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final launched = await h.container
          .read(fanOutServiceProvider)
          .launch(
            repository: repository(),
            installations: [roverInstall, flakyInstall],
            prompt: '  compare these  ',
          );

      final controller = h.container.read(
        terminalSessionsControllerProvider.notifier,
      );
      for (final result in launched.started) {
        final paneId = SessionDao(h.db).getById(result.session.id)!.paneId!;
        final instance =
            controller.instanceFor(paneId)! as FakeTerminalInstance;
        expect(instance.agentLaunch!.arguments, contains('compare these'));
      }
    });
  });

  group('a partial launch keeps what started', () {
    test('the agents that started are returned, not discarded', () async {
      final h = harness(paneFailsFor: {'flakyCli'});
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final launched = await h.container
          .read(fanOutServiceProvider)
          .launch(
            repository: repository(),
            installations: [roverInstall, flakyInstall, secondRoverInstall],
            prompt: 'go',
          );

      // This is the bug: `Future.wait` threw here and took the two running
      // sessions with it, leaving them alive and unreferenced.
      expect(launched.started.map((r) => r.agentId), ['roverCli', 'roverCli']);
      expect(launched.failures.map((f) => f.agentId), ['flakyCli']);
      expect(launched.requested, 3);
      expect(launched.hasFailures, isTrue);
      expect(launched.partialSummary, '2 of 3 agents started; 1 failed.');
    });

    test('the failure names the installation and carries the error', () async {
      final h = harness(paneFailsFor: {'flakyCli'});
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final launched = await h.container
          .read(fanOutServiceProvider)
          .launch(
            repository: repository(),
            installations: [roverInstall, flakyInstall],
            prompt: 'go',
          );

      final failure = launched.failures.single;
      expect(failure.installation.id, flakyInstall.id);
      expect('${failure.error}', contains('could not start flakyCli'));
    });

    test(
      'the started sessions are running rows; the failed one is failed',
      () async {
        final h = harness(paneFailsFor: {'flakyCli'});
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);

        final launched = await h.container
            .read(fanOutServiceProvider)
            .launch(
              repository: repository(),
              installations: [roverInstall, flakyInstall],
              prompt: 'go',
            );

        final dao = SessionDao(h.db);
        expect(
          dao.getById(launched.started.single.session.id)!.status,
          SessionStatus.running,
        );
        expect(
          dao.getAll().where((s) => s.status == SessionStatus.failed),
          hasLength(1),
        );
      },
    );

    test(
      'every agent failing is a launch with no results, not a throw',
      () async {
        final h = harness(paneFailsFor: {'roverCli', 'flakyCli'});
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);

        final launched = await h.container
            .read(fanOutServiceProvider)
            .launch(
              repository: repository(),
              installations: [roverInstall, flakyInstall],
              prompt: 'go',
            );

        expect(launched.started, isEmpty);
        expect(launched.failures, hasLength(2));
        expect(launched.partialSummary, '0 of 2 agents started; 2 failed.');
      },
    );
  });

  group('diff', () {
    test('asks git for the worktree\'s diff', () async {
      final h = harness(
        git: (request) => request.arguments.contains('diff')
            ? const CommandResult(
                exitCode: 0,
                stdout: 'diff --git a/x b/x',
                stderr: '',
              )
            : const CommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final service = h.container.read(fanOutServiceProvider);
      final launched = await service.launch(
        repository: repository(),
        installations: [roverInstall, flakyInstall],
        prompt: 'go',
      );

      final result = launched.started.first;
      expect(await service.diff(result), 'diff --git a/x b/x');
      final diffCall = h.git.requests.lastWhere(
        (r) => r.arguments.contains('diff'),
      );
      expect(diffCall.arguments, contains(result.session.worktree!.path));
    });

    test(
      'a result with no worktree diffs to nothing rather than throwing',
      () async {
        final h = harness();
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);

        final result = FanOutResult(
          session: session(id: 'no-wt'),
          agentId: 'roverCli',
          repository: repository(),
        );
        expect(await h.container.read(fanOutServiceProvider).diff(result), '');
      },
    );
  });

  group('mergeWinner', () {
    test('refuses a winner with uncommitted changes', () async {
      final h = harness(git: _gitWithStatus(' M lib/main.dart'));
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final service = h.container.read(fanOutServiceProvider);
      final launched = await service.launch(
        repository: repository(),
        installations: [roverInstall, flakyInstall],
        prompt: 'go',
      );

      await expectLater(
        service.mergeWinner(launched.started.first),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('still has uncommitted changes'),
          ),
        ),
      );
      // And nothing was merged.
      expect(
        h.git.requests.where((r) => r.arguments.contains('merge')),
        isEmpty,
      );
    });

    test('merges the session branch when the worktree is clean', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final service = h.container.read(fanOutServiceProvider);
      final launched = await service.launch(
        repository: repository(),
        installations: [roverInstall, flakyInstall],
        prompt: 'go',
      );
      final winner = launched.started.first;

      await service.mergeWinner(winner);

      final merge = h.git.requests.lastWhere(
        (r) => r.arguments.contains('merge'),
      );
      expect(merge.arguments, contains(repository().path.path));
      expect(merge.arguments, contains('session/${winner.session.id}'));
    });

    test('refuses a result that has no worktree', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      await expectLater(
        h.container
            .read(fanOutServiceProvider)
            .mergeWinner(
              FanOutResult(
                session: session(id: 'no-wt'),
                agentId: 'roverCli',
                repository: repository(),
              ),
            ),
        throwsA(isA<StateError>()),
      );
    });
  });
}

CommandResult Function(CommandRequest) _gitWithStatus(String porcelain) =>
    (request) => request.arguments.contains('status')
    ? CommandResult(exitCode: 0, stdout: porcelain, stderr: '')
    : const CommandResult(exitCode: 0, stdout: '', stderr: '');
