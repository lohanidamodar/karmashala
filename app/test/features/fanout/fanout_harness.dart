/// The shared fan-out test harness: a real `SessionLauncher` over fake terminals
/// and a fake git, so worktree creation, session rows and pane launch are the
/// real code paths rather than a friendlier stand-in.
library;

import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/permission_fixtures.dart';
import '../../support/test_machine.dart';
import '../git/worktree_processes.dart';
import '../terminal/fake_instance.dart';

/// Parallel worktree fan-out: run one prompt on several agents at once, compare
/// their diffs, merge one, discard the rest.
///
/// The feature shipped with no tests at all. These cover the four things it
/// decides — what input it refuses, what it does when only *some* agents start,
/// what it will merge, and what it will delete.
const _rover = AgentDescriptor(
  id: 'roverCli',
  displayName: 'Rover CLI',
  binaries: AgentBinaries(windows: ['rover'], posix: ['rover']),
  launch: AgentLaunchSpec(
    baseArguments: [],
    permission: testPermissionSupport,
    prompt: AgentPromptSupport.positional(),
  ),
);

const _flaky = AgentDescriptor(
  id: 'flakyCli',
  displayName: 'Flaky CLI',
  binaries: AgentBinaries(windows: ['flaky'], posix: ['flaky']),
  launch: AgentLaunchSpec(
    baseArguments: [],
    permission: testPermissionSupport,
    prompt: AgentPromptSupport.positional(),
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
  TestMachine db,
  FakeCommandRunner git,
  FakeDataServer server,
});

/// Builds the fan-out under a real [SessionLauncher] over fake terminals and a
/// fake git, so worktree creation, session rows and pane launch are the real
/// code paths rather than a friendlier stand-in.
Harness harness({
  /// Agent ids whose pane refuses to be created, to force a partial launch.
  Set<String> paneFailsFor = const {},
  CommandResult Function(CommandRequest request)? git,

  /// Where the project, repository, environment and installations are
  /// seeded; mirrored into the database for the session rows' foreign keys.
  required FakeDataServer server,

  /// A client of [server] for the container to read through.
  required DataClient client,
}) {
  final db = TestMachine();
  final data = server.runsOn(db);
  // The server starts every agent (slice 5b): one that will not start is its
  // refusal, with the row it wrote marked failed.
  server.sessionWork.failsFor = paneFailsFor;

  final runner = FakeCommandRunner(
    responder:
        git ?? (_) => const CommandResult(exitCode: 0, stdout: '', stderr: ''),
    // A worktree's checkout is streamed now; a git stream here finishes at once.
    processFactory: (request) =>
        request.executable == 'git' ? finishedGit() : FakeProcessHandle(),
  );

  final container = ProviderContainer(
    overrides: [
      dataClientProvider.overrideWithValue(client),
      ...fakeTerminalOverrides(
        machine: db,
        instanceFactory: paneFailsFor.isEmpty
            ? null
            : ({
                required id,
                required profile,
                workingDirectory,
                restoredScrollback,
                shellIntegration = false,
                agentLaunch,
                adoptTerminal,
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
                  adoptTerminal: adoptTerminal,
                );
              },
      ),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      idGeneratorProvider.overrideWithValue(SequentialIdGenerator('sesid00')),
      agentRegistryProvider.overrideWithValue(
        const AgentRegistry([
          DataOnlyAgentAdapter(_rover),
          DataOnlyAgentAdapter(_flaky),
        ]),
      ),
      settingsControllerProvider.overrideWith(
        () => _StaticSettings(const Settings()),
      ),
      // Nothing here may shell out: git is faked, and the host runner is faked
      // so no path can reach a real terminal.
      commandRunnerFactoryProvider.overrideWithValue(
        server.gitWork.serve(FakeCommandRunnerFactory(fallback: runner)),
      ),
      hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
    ],
  );
  return (container: container, db: db, git: runner, server: data);
}

/// [harness] whose container reads the workspace from a connected
/// [FakeDataServer].
Future<Harness> connectedHarness({
  Set<String> paneFailsFor = const {},
  CommandResult Function(CommandRequest request)? git,
}) async {
  final server = FakeDataServer(clock: () => testTime);
  server.environmentRows.upsert(windowsEnv());
  server.projectRows.insert(project());
  server.repositoryRows.insert(repository());
  server.installationRows
    ..insert(roverInstall)
    ..insert(flakyInstall)
    ..insert(secondRoverInstall);
  return harness(
    paneFailsFor: paneFailsFor,
    git: git,
    server: server,
    client: await server.connect(),
  );
}
