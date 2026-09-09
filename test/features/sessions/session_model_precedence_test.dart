import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_working_directory.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session_launch.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// `session_permission_precedence_test.dart`'s twin, one field over: the same
/// question asked of the per-agent **model** default, and answered on the only
/// surface where a model is ever real — the pane's command line.
///
/// An agent that takes `--model` at launch, so a flag on the command line names
/// the winning model with nothing else in the way.
const _rover = AgentDescriptor(
  id: 'roverCli',
  displayName: 'Rover CLI',
  binaries: AgentBinaries(windows: ['rover'], posix: ['rover']),
  launch: AgentLaunchSpec(
    model: AgentModelSupport.atLaunchOnly(
      flag: '--model',
      models: [
        AgentModel(id: 'fast', label: 'Fast', summary: 'Quick work.'),
        AgentModel(id: 'deep', label: 'Deep', summary: 'Hard work.'),
      ],
      evidence: 'invented for this test',
    ),
    interactiveResume: AgentResume.flag('--continue'),
  ),
);

/// The real [SettingsController] over the in-memory database, deliberately: the
/// questions here are what happens **when the default changes** and **after a
/// restart**, and a frozen fake can answer neither.
({ProviderContainer container, AppDatabase db}) harness({AppDatabase? reopen}) {
  final db = reopen ?? AppDatabase.memory();
  if (reopen == null) {
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation(agentId: 'roverCli'));
  }
  final container = ProviderContainer(
    overrides: [
      ...fakeTerminalOverrides(database: db),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
      agentRegistryProvider.overrideWithValue(const AgentRegistry([_rover])),
      sessionDirectoryPresentProvider.overrideWithValue((_) => true),
    ],
  );
  return (container: container, db: db);
}

extension on ProviderContainer {
  SessionLauncher get launcher => read(sessionLauncherProvider);

  void setDefaultModel(String? modelId) =>
      read(settingsControllerProvider.notifier).setDefaultModel(
        'roverCli',
        modelId,
      );

  /// The arguments the pane was actually started with — the only place a model
  /// is ever real.
  List<String> argumentsOf(String paneId) => read(
    terminalSessionsControllerProvider.notifier,
  ).instanceFor(paneId)!.agentLaunch!.arguments;
}

void seedStopped(AppDatabase db, {String? model}) {
  SessionDao(db).insert(
    session(id: 'src', status: SessionStatus.completed).copyWith(
      externalSessionId: 'cli-1',
      modelId: model,
    ),
  );
}

Future<SessionLaunchResult> resume(ProviderContainer container) =>
    container.launcher.launch(
      SessionLaunchRequest(
        repository: repository(),
        installation: agentInstallation(agentId: 'roverCli'),
        title: 'Continue',
        purpose: SessionPurpose.existingSession,
        resumeExternalSessionId: 'cli-1',
      ),
    );

Future<SessionLaunchResult> startNew(
  ProviderContainer container, {
  String? modelOverride,
}) => container.launcher.launch(
  SessionLaunchRequest(
    repository: repository(),
    installation: agentInstallation(agentId: 'roverCli'),
    title: 'Fresh',
    purpose: SessionPurpose.newSession,
    modelOverride: modelOverride,
  ),
);

void main() {
  test('the shipped default names no model, and passes none', () async {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);

    final launched = await startNew(h.container);

    // "Let the agent choose" is the setting nobody has changed, and it is an
    // answer rather than a gap: no flag reaches the CLI at all.
    expect(h.container.argumentsOf(launched.paneId!), isNot(contains('--model')));
    final effective = h.container.launcher.effectiveModelFor(
      launched.session.id,
    )!;
    expect(effective.modelId, isNull);
    expect(effective.defaultModelId, isNull);
    expect(effective.inherited, isTrue);
  });

  test('the Settings default reaches the chip and the command line, once', () async {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    h.container.setDefaultModel('deep');

    final launched = await startNew(h.container);

    // One resolution, two readers: what the chip draws and what the pane was
    // started with are the same call's answer, so they cannot disagree.
    final effective = h.container.launcher.effectiveModelFor(
      launched.session.id,
    )!;
    expect(effective.modelId, 'deep');
    expect(effective.inherited, isTrue);
    expect(h.container.argumentsOf(launched.paneId!), ['--model', 'deep']);
    // And nothing was written on the row: following the default is the absence
    // of a choice, not a copy of one.
    expect(SessionDao(h.db).getById(launched.session.id)!.modelId, isNull);
  });

  test('a session\'s own model beats the Settings default at launch', () async {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    h.container.setDefaultModel('deep');

    final launched = await startNew(h.container, modelOverride: 'fast');

    expect(h.container.argumentsOf(launched.paneId!), ['--model', 'fast']);
    final effective = h.container.launcher.effectiveModelFor(
      launched.session.id,
    )!;
    expect(effective.modelId, 'fast');
    expect(effective.inherited, isFalse);
    expect(effective.defaultModelId, 'deep');
  });

  test('changing the default moves the session that never chose, and only it', () {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    seedStopped(h.db);
    SessionDao(h.db).insert(
      session(id: 'own', status: SessionStatus.completed).copyWith(
        externalSessionId: 'cli-2',
        modelId: 'fast',
      ),
    );

    h.container.setDefaultModel('deep');

    expect(h.container.launcher.effectiveModelFor('src')!.modelId, 'deep');
    expect(h.container.launcher.effectiveModelFor('own')!.modelId, 'fast');

    h.container.setDefaultModel('fast');
    expect(h.container.launcher.effectiveModelFor('src')!.modelId, 'fast');
  });

  test('a resume runs on the default the setting names now', () async {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    seedStopped(h.db);
    h.container.setDefaultModel('deep');

    final launched = await resume(h.container);

    expect(h.container.argumentsOf(launched.paneId!), [
      '--model',
      'deep',
      '--continue',
      'cli-1',
    ]);
    expect(SessionDao(h.db).getById('src')!.modelId, isNull);
  });

  test('back to "let the agent choose", and the flag goes with it', () async {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    h.container.setDefaultModel('deep');

    // Null is a value here, not a missing argument: "let the agent choose" is a
    // state the user can go back to, and without it the first pick would be
    // irreversible.
    h.container.setDefaultModel(null);
    seedStopped(h.db);

    final launched = await resume(h.container);
    expect(h.container.argumentsOf(launched.paneId!), ['--continue', 'cli-1']);
    expect(h.container.launcher.defaultModelFor('roverCli'), isNull);
  });

  test('the default survives a restart', () async {
    final first = harness();
    addTearDown(first.db.close);
    first.container.setDefaultModel('deep');
    seedStopped(first.db);
    first.container.dispose();

    // A new container over the same database is what a restart is: settings
    // and sessions are both re-read from disk.
    final second = harness(reopen: first.db);
    addTearDown(second.container.dispose);

    final effective = second.container.launcher.effectiveModelFor('src')!;
    expect(effective.modelId, 'deep');
    expect(effective.inherited, isTrue);

    final launched = await resume(second.container);
    expect(second.container.argumentsOf(launched.paneId!), [
      '--model',
      'deep',
      '--continue',
      'cli-1',
    ]);
  });
}
